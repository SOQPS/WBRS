"""Native-only bounded HTTP pages from the current canonical chat tables.

Uses the mutation service's existing transaction pool. No Firebase fallback,
arbitrary audience, raw legacy payload, client URL or independent write path.
"""
from __future__ import annotations

import re
from typing import NamedTuple
from urllib.parse import parse_qsl

from native_auth import NativeRejected, NativeUnavailable, NativeRateLimited
from native_sessions import NativeIdentity
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, MAX_INTEGER
from runtime_reads import RuntimeReadRejected


class RuntimeReadHttpReply(NamedTuple):
    status: str
    payload: dict
    authenticate: bool = False
    retry: bool = False


def _route(environ):
    path = environ.get("PATH_INFO", "")
    if not isinstance(path, str) or len(path) > 1000:
        return None
    try:
        path = path.encode("latin-1").decode("utf-8")
    except UnicodeError:
        return None
    if path == "/v1/runtime/chats":
        return "chats", None
    if path == "/v1/runtime/events":
        return "events", None
    match = re.fullmatch(r"/v1/runtime/chats/([^/]{1,191})/messages", path)
    if match and environ.get("REQUEST_METHOD") != "POST":
        if any(ord(c) < 32 or ord(c) == 127 for c in match[1]):
            return None
        return "messages", match[1]
    return None


def _query(environ, operation):
    raw = environ.get("QUERY_STRING", "")
    if (not isinstance(raw, str) or len(raw) > 4096
            or re.search(r"%(?![a-fA-F0-9]{2})", raw)
            or any(ord(c) < 32 or ord(c) > 126 for c in raw)):
        raise RuntimeInvalidRequest()
    try:
        entries = parse_qsl(raw, keep_blank_values=True, strict_parsing=True,
                            encoding="utf-8", errors="strict", max_num_fields=2)
    except (ValueError, UnicodeError):
        raise RuntimeInvalidRequest() from None
    values = dict(entries)
    cursor_name = {"chats": "cursor", "messages": "beforeSequence",
                   "events": "afterEventId"}[operation]
    if len(entries) != len(values) or set(values) - {"limit", cursor_name}:
        raise RuntimeInvalidRequest()
    limit = values.get("limit", "50")
    if re.fullmatch(r"[1-9][0-9]{0,2}", limit) is None or int(limit) > 100:
        raise RuntimeInvalidRequest()
    result = {"limit": int(limit)}
    if cursor_name in values:
        cursor = values[cursor_name]
        if operation == "chats":
            if not cursor or len(cursor) > 2048 or re.fullmatch(r"[A-Za-z0-9_-]+", cursor) is None:
                raise RuntimeInvalidRequest()
            result["cursor"] = cursor
        else:
            if re.fullmatch(r"0|[1-9][0-9]{0,18}", cursor) is None:
                raise RuntimeInvalidRequest()
            value = int(cursor)
            if value > MAX_INTEGER or (operation == "messages" and value == 0):
                raise RuntimeInvalidRequest()
            result["before_sequence" if operation == "messages" else "after_event_id"] = value
    return result


class RuntimeReadHttp:
    def __init__(self, env, store, *, read_factory=None):
        self._enabled = (env.get("CLRS_RUNTIME_WRITES_ENABLED") == "1"
            and env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") == "canonical-current-v1")
        self._reader = None
        if self._enabled and store is not None:
            try:
                if read_factory is None:
                    from runtime_reads import RuntimeReadService
                    read_factory = RuntimeReadService.from_env
                self._reader = read_factory(store, env)
            except Exception:
                pass

    def close(self):
        # The parent HTTP adapter owns and closes the shared transaction pool.
        self._reader = None

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        route = _route(environ)
        if route is None:
            return None
        if not self._enabled:
            return RuntimeReadHttpReply("404 Not Found", {"error": "not_found"})
        if environ.get("REQUEST_METHOD") != "GET":
            return RuntimeReadHttpReply("405 Method Not Allowed", {"error": "method_not_allowed"})
        operation, resource = route
        try:
            if (environ.get("HTTP_TRANSFER_ENCODING")
                    or environ.get("CONTENT_LENGTH", "") not in ("", "0")):
                raise RuntimeInvalidRequest()
            options = _query(environ, operation)
            header = environ.get("HTTP_AUTHORIZATION", "")
            if (not isinstance(header, str) or not header.startswith("Bearer na1.")
                    or len(header) > 135 or any(c.isspace() for c in header[7:])
                    or not native_configured):
                raise NativeRejected()
            if native_service is None or self._reader is None:
                raise NativeUnavailable()
            token = header[7:]
            identity = native_service.authorize(token, peer=environ.get("REMOTE_ADDR", ""))
            if type(identity) is not NativeIdentity:
                raise NativeUnavailable()
            if operation == "chats":
                result = self._reader.own_chats(identity, access_token=token, **options)
            elif operation == "messages":
                result = self._reader.messages(identity, resource, access_token=token, **options)
            else:
                result = self._reader.own_events(identity, access_token=token, **options)
            if type(result) is not dict:
                raise NativeUnavailable()
            return RuntimeReadHttpReply("200 OK", result)
        except RuntimeInvalidRequest:
            return RuntimeReadHttpReply("400 Bad Request", {"error": "invalid_request"})
        except RuntimeReadRejected:
            return RuntimeReadHttpReply("404 Not Found", {"error": "not_found"})
        except (NativeRejected, RuntimeRejected):
            return RuntimeReadHttpReply("401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
        except NativeRateLimited:
            return RuntimeReadHttpReply("429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except Exception:
            return RuntimeReadHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
