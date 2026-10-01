"""Isolated CLRS API draft for an existing free Timeweb App Platform stand.

The deployed smoke branch remains separate. This draft has no SQL editor,
admin route, media access, legacy credentials, or cross-account profile read.
"""

import json
import os
import re

from auth_bridge import AuthRejected, AuthUnavailable, AuthenticationError, verify_firebase_id_token
from profile_store import AccountUnavailable, DatabaseUnavailable, probe_database, read_own_profile
from native_auth import (MAX_BODY_BYTES, NativeAuthService, NativeRateLimited,
                         NativeRejected, NativeUnavailable, parse_login_body)
from native_credentials import unique_json, CredentialUnavailable
from legacy_conversation_http import LegacyConversationHttp


def _reply(start_response, status, payload, *, head=False, authenticate=False, retry=False):
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    headers = [
        ("Content-Type", "application/json; charset=utf-8"),
        ("Content-Length", str(len(body))),
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
    ]
    if authenticate:
        headers.append(("WWW-Authenticate", "Bearer"))
    if retry:
        headers.append(("Retry-After", "60"))
    start_response(status, headers)
    return [b"" if head else body]


class InvalidBody(Exception):
    pass


def _body(environ):
    # Bound the read itself, not only the decoded JSON. Socket deadlines are
    # enforced by the server; chunked/unknown-length input is never accepted.
    if environ.get("HTTP_TRANSFER_ENCODING"):
        raise InvalidBody()
    length = environ.get("CONTENT_LENGTH", "")
    if not isinstance(length, str) or re.fullmatch(r"[0-9]{1,5}", length) is None:
        raise InvalidBody()
    length = int(length)
    if not 1 <= length <= MAX_BODY_BYTES:
        raise InvalidBody()
    content_type = environ.get("CONTENT_TYPE", "").lower()
    if content_type not in ("application/json", "application/json; charset=utf-8"):
        raise InvalidBody()
    try:
        raw = environ["wsgi.input"].read(length)
    except Exception:
        raise InvalidBody() from None
    if not isinstance(raw, bytes) or len(raw) != length:
        raise InvalidBody()
    return raw


def _json_body(environ, keys):
    try:
        result = unique_json(_body(environ).decode("utf-8"))
    except (CredentialUnavailable, UnicodeError):
        raise InvalidBody() from None
    if set(result) != keys:
        raise InvalidBody()
    return result


def _bearer(environ):
    header = environ.get("HTTP_AUTHORIZATION", "")
    if (not isinstance(header, str) or not header.startswith("Bearer ")
            or len(header) > 8192 or not header[7:]
            or any(char.isspace() for char in header[7:])):
        raise NativeRejected()
    return header[7:]


def _peer(environ):
    # The hosting proxy's socket identity is used conservatively. Do not trust
    # caller-controlled X-Forwarded-For to bypass the process rate limit.
    return environ.get("REMOTE_ADDR", "")


def create_app(*, env=None, verify_token=verify_firebase_id_token,
               profile_reader=read_own_profile, database_probe=probe_database,
               native_service_factory=NativeAuthService.from_env,
               legacy_http_factory=LegacyConversationHttp):
    """Construct WSGI app with injectable dependencies for offline tests."""
    if env is None:
        env = os.environ
    native_service = None
    legacy_http = legacy_http_factory(env)
    native_configured = (env.get("CLRS_NATIVE_AUTH_ENABLED") == "1"
                         and env.get("CLRS_NATIVE_AUTH_WRITES_ENABLED") == "1")
    if native_configured:
        try:
            native_service = native_service_factory(env)
        except Exception:
            # Invalid secret/configuration closes routes without exposing it.
            native_service = None

    def application(environ, start_response):
        method = environ.get("REQUEST_METHOD", "")
        path = environ.get("PATH_INFO", "")
        smoke = env.get("CLRS_STAGING_SMOKE_ENABLED") == "1"
        api = env.get("CLRS_API_DRAFT_ENABLED") == "1"
        if smoke and api:
            if path in ("/", "/health", "/healthz", "/readyz") and method in ("GET", "HEAD"):
                return _reply(start_response, "503 Service Unavailable",
                              {"state": "conflicting_modes"}, head=method == "HEAD")
            return _reply(start_response, "404 Not Found", {"error": "not_found"})

        if path in ("/", "/health", "/healthz") and method in ("GET", "HEAD"):
            state = "api_draft" if api else "smoke_only"
            return _reply(start_response, "200 OK",
                          {"service": "clrs-timeweb-stand", "state": state},
                          head=method == "HEAD")
        if path == "/readyz" and method in ("GET", "HEAD"):
            # No real-data import, privacy validation, or restore drill exists.
            connected = False
            if api:
                try:
                    connected = database_probe(env=env) is True
                except Exception:
                    connected = False
            return _reply(start_response, "503 Service Unavailable",
                          {"state": "migration_incomplete" if api else "api_not_configured",
                           "database_connected": connected},
                          head=method == "HEAD")

        if api and path in ("/v1/auth/login", "/v1/auth/refresh", "/v1/auth/logout"):
            if not native_configured:
                return _reply(start_response, "404 Not Found", {"error": "not_found"})
            if method != "POST":
                return _reply(start_response, "405 Method Not Allowed", {"error": "method_not_allowed"})
            if native_service is None:
                return _reply(start_response, "503 Service Unavailable", {"error": "service_unavailable"})
            if environ.get("QUERY_STRING"):
                return _reply(start_response, "400 Bad Request", {"error": "invalid_request"})
            try:
                if path == "/v1/auth/login":
                    try:
                        body = parse_login_body(_body(environ))
                    except NativeRejected:
                        raise InvalidBody() from None
                    payload = native_service.login(body, peer=_peer(environ))
                elif path == "/v1/auth/refresh":
                    body = _json_body(environ, {"refreshToken"})
                    payload = native_service.refresh(body["refreshToken"], peer=_peer(environ))
                else:
                    body = _json_body(environ, {"allSessions"})
                    if type(body["allSessions"]) is not bool:
                        raise InvalidBody()
                    payload = native_service.logout(_bearer(environ), peer=_peer(environ),
                                                    all_sessions=body["allSessions"])
            except InvalidBody:
                return _reply(start_response, "400 Bad Request", {"error": "invalid_request"})
            except NativeRejected:
                return _reply(start_response, "401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
            except NativeRateLimited:
                return _reply(start_response, "429 Too Many Requests", {"error": "rate_limited"}, retry=True)
            except Exception:
                return _reply(start_response, "503 Service Unavailable", {"error": "service_unavailable"})
            return _reply(start_response, "200 OK", payload)

        if api:
            legacy_reply = legacy_http.dispatch(environ, native_service=native_service,
                                              native_configured=native_configured)
            if legacy_reply is not None:
                return _reply(start_response, legacy_reply.status, legacy_reply.payload,
                              authenticate=legacy_reply.authenticate, retry=legacy_reply.retry)

        if not api or path != "/v1/me/profile" or method != "GET":
            return _reply(start_response, "404 Not Found", {"error": "not_found"})

        if environ.get("QUERY_STRING"):
            return _reply(start_response, "400 Bad Request", {"error": "invalid_request"})
        try:
            token = _bearer(environ)
        except NativeRejected:
            return _reply(start_response, "401 Unauthorized",
                          {"error": "unauthorized"}, authenticate=True)
        try:
            if token.startswith(("na1.", "nr1.")):
                if not native_configured:
                    raise NativeRejected()
                if native_service is None:
                    raise NativeUnavailable()
                uid = native_service.authorize(token, peer=_peer(environ)).uid
            else:
                if not env.get("FIREBASE_PROJECT_ID") or not env.get("FIREBASE_WEB_API_KEY"):
                    raise AuthUnavailable()
                uid = verify_token(token,
                                   project_id=env["FIREBASE_PROJECT_ID"],
                                   web_api_key=env["FIREBASE_WEB_API_KEY"])
        except (AuthRejected, NativeRejected):
            return _reply(start_response, "401 Unauthorized",
                          {"error": "unauthorized"}, authenticate=True)
        except NativeRateLimited:
            return _reply(start_response, "429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except (AuthUnavailable, AuthenticationError, NativeUnavailable):
            return _reply(start_response, "503 Service Unavailable",
                          {"error": "service_unavailable"})
        except Exception:
            return _reply(start_response, "503 Service Unavailable",
                          {"error": "service_unavailable"})
        try:
            profile = profile_reader(uid, env=env)
        except AccountUnavailable:
            return _reply(start_response, "404 Not Found", {"error": "not_found"})
        except DatabaseUnavailable:
            return _reply(start_response, "503 Service Unavailable",
                          {"error": "service_unavailable"})
        except Exception:
            return _reply(start_response, "503 Service Unavailable",
                          {"error": "service_unavailable"})
        return _reply(start_response, "200 OK", {"profile": profile})

    return application


app = create_app()


if __name__ == "__main__":
    smoke_enabled = os.environ.get("CLRS_STAGING_SMOKE_ENABLED") == "1"
    api_enabled = os.environ.get("CLRS_API_DRAFT_ENABLED") == "1"
    if smoke_enabled == api_enabled:
        raise SystemExit("Select exactly one isolated CLRS stand mode")
    try:
        port = int(os.environ.get("PORT", "5005"))
    except ValueError as exc:
        raise SystemExit("Invalid stand port") from exc
    if not 1 <= port <= 65535:
        raise SystemExit("Invalid stand port")
    from http_runtime import make_bounded_server
    with make_bounded_server("0.0.0.0", port, app) as server:
        server.serve_forever()
