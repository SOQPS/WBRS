"""Firebase ID-token bridge for a future CLRS API.

Requires ``cryptography``. No request is made until ``verify`` is called.
The caller must separately authorize the returned UID against the current
CLRS account lifecycle and the requested resource.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass
from functools import lru_cache
import json
import re
import threading
import time
from binascii import Error as Base64Error
from typing import Callable, Mapping, NamedTuple, Optional
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa


X509_URL = (
    "https://www.googleapis.com/robot/v1/metadata/x509/"
    "securetoken@system.gserviceaccount.com"
)
LOOKUP_URL = "https://identitytoolkit.googleapis.com/v1/accounts:lookup"
MAX_TOKEN_BYTES = 16 * 1024
MAX_CERT_RESPONSE_BYTES = 128 * 1024
MAX_LOOKUP_RESPONSE_BYTES = 64 * 1024
MAX_CACHE_SECONDS = 24 * 60 * 60


class AuthenticationError(Exception):
    """Safe public error type for the API to convert into an HTTP response."""


class AuthRejected(AuthenticationError):
    """The supplied token or its current Firebase account is not authorized."""


class AuthUnavailable(AuthenticationError):
    """Current Firebase authorization could not be confirmed."""


@dataclass(frozen=True)
class AuthenticatedIdentity:
    uid: str
    issued_at: int
    authenticated_at: int
    expires_at: int


class HttpResponse(NamedTuple):
    status: int
    headers: Mapping[str, str]
    body: bytes


Transport = Callable[
    [str, str, Mapping[str, str], Optional[bytes], float], HttpResponse
]


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def _default_transport(
    method: str, url: str, headers: Mapping[str, str],
    body: Optional[bytes], timeout: float,
) -> HttpResponse:
    # Fixed HTTPS hosts only. Ignore ambient proxy settings so an ID token is
    # never forwarded through an unexpected process-level HTTP proxy.
    opener = build_opener(ProxyHandler({}), _NoRedirect())
    request = Request(url, data=body, headers=dict(headers), method=method)
    try:
        with opener.open(request, timeout=timeout) as response:
            return HttpResponse(
                response.status, dict(response.headers.items()),
                response.read(MAX_CERT_RESPONSE_BYTES + 1),
            )
    except HTTPError as error:
        error.close()
        return HttpResponse(error.code, {}, b"")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON field")
        result[key] = value
    return result


def _json_object(raw: bytes):
    try:
        value = json.loads(
            raw.decode("utf-8"), object_pairs_hook=_unique_object,
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError()),
        )
    except (UnicodeError, ValueError, TypeError):
        raise ValueError("invalid JSON") from None
    if not isinstance(value, dict):
        raise ValueError("invalid JSON object")
    return value


def _jwt_part(part: str, max_bytes: int) -> bytes:
    if not part or re.fullmatch(r"[A-Za-z0-9_-]+", part) is None or len(part) % 4 == 1:
        raise AuthRejected("Invalid Firebase ID token")
    try:
        decoded = base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
    except (ValueError, Base64Error):
        raise AuthRejected("Invalid Firebase ID token") from None
    if len(decoded) > max_bytes or base64.urlsafe_b64encode(decoded).rstrip(b"=").decode() != part:
        raise AuthRejected("Invalid Firebase ID token")
    return decoded


def _integer(value) -> bool:
    return type(value) is int


def _cache_seconds(headers: Mapping[str, str]) -> int:
    cache_control = next(
        (str(value) for key, value in headers.items()
         if key.lower() == "cache-control"), "",
    )
    match = re.search(r"(?:^|,)\s*max-age\s*=\s*(\d+)\s*(?:,|$)", cache_control, re.I)
    return min(int(match.group(1)), MAX_CACHE_SECONDS) if match else 0


class FirebaseAuthBridge:
    """Verify a signed Firebase ID token and check current account state.

    ``transport`` is injectable so tests never contact Google. The API key is
    the Firebase client API key, not an Admin credential; it is not logged.
    """

    def __init__(
        self, project_id: str, api_key: str,
        transport: Transport = _default_transport,
        now: Callable[[], float] = time.time,
        timeout: float = 5.0,
    ):
        if (re.fullmatch(r"[a-z][a-z0-9-]{4,62}", project_id or "") is None
                or re.fullmatch(r"[A-Za-z0-9_-]{10,200}", api_key or "") is None
                or not callable(transport) or not callable(now)
                or not isinstance(timeout, (int, float)) or not 0 < timeout <= 30):
            raise ValueError("Invalid Firebase Auth bridge configuration")
        self._project_id = project_id
        self._lookup_url = LOOKUP_URL + "?key=" + quote(api_key, safe="")
        self._transport = transport
        self._now = now
        self._timeout = float(timeout)
        self._keys = {}
        self._keys_expire_at = 0.0
        self._key_lock = threading.Lock()

    def _request(
        self, method: str, url: str, headers: Mapping[str, str],
        body: Optional[bytes], max_bytes: int,
    ) -> HttpResponse:
        try:
            response = self._transport(method, url, headers, body, self._timeout)
            if (not isinstance(response, HttpResponse)
                    or type(response.status) is not int
                    or not isinstance(response.body, bytes)
                    or len(response.body) > max_bytes):
                raise ValueError("Invalid provider response")
            return response
        except Exception:
            # Transport errors can embed the API key or request body.
            raise AuthUnavailable("Firebase Auth check unavailable") from None

    def _load_keys(self) -> None:
        response = self._request(
            "GET", X509_URL, {"Accept": "application/json"}, None,
            MAX_CERT_RESPONSE_BYTES,
        )
        if response.status != 200:
            raise AuthUnavailable("Firebase Auth check unavailable")
        try:
            certificates = _json_object(response.body)
            if not 1 <= len(certificates) <= 32:
                raise ValueError("Invalid certificate count")
            loaded = {}
            for kid, pem in certificates.items():
                if (not isinstance(kid, str) or not 1 <= len(kid) <= 200
                        or not isinstance(pem, str) or len(pem) > 10000):
                    raise ValueError("Invalid certificate")
                key = x509.load_pem_x509_certificate(pem.encode("ascii")).public_key()
                if not isinstance(key, rsa.RSAPublicKey) or key.key_size < 2048:
                    raise ValueError("Invalid signing key")
                loaded[kid] = key
            self._keys = loaded
            self._keys_expire_at = self._now() + _cache_seconds(response.headers)
        except Exception:
            raise AuthUnavailable("Firebase signing keys unavailable") from None

    def _key(self, kid: str):
        with self._key_lock:
            if self._now() >= self._keys_expire_at:
                self._load_keys()
            key = self._keys.get(kid)
            if key is None:
                raise AuthRejected("Invalid Firebase ID token")
            return key

    def _signed_identity(self, token: str) -> AuthenticatedIdentity:
        try:
            token_size = len(token.encode("utf-8")) if isinstance(token, str) else 0
        except UnicodeError:
            token_size = 0
        if not 0 < token_size <= MAX_TOKEN_BYTES:
            raise AuthRejected("Invalid Firebase ID token")
        parts = token.split(".")
        if len(parts) != 3:
            raise AuthRejected("Invalid Firebase ID token")
        encoded_header, encoded_claims, encoded_signature = parts
        try:
            header = _json_object(_jwt_part(encoded_header, 8 * 1024))
        except ValueError:
            raise AuthRejected("Invalid Firebase ID token") from None
        kid = header.get("kid")
        if (header.get("alg") != "RS256" or not isinstance(kid, str)
                or not 1 <= len(kid) <= 200
                or header.get("typ", "JWT") != "JWT" or "crit" in header):
            raise AuthRejected("Invalid Firebase ID token")
        signature = _jwt_part(encoded_signature, 8 * 1024)
        key = self._key(kid)
        try:
            key.verify(
                signature,
                (encoded_header + "." + encoded_claims).encode("ascii"),
                padding.PKCS1v15(), hashes.SHA256(),
            )
        except (InvalidSignature, ValueError, UnicodeError):
            raise AuthRejected("Invalid Firebase ID token") from None
        try:
            claims = _json_object(_jwt_part(encoded_claims, 8 * 1024))
        except ValueError:
            raise AuthRejected("Invalid Firebase ID token") from None
        issued = claims.get("iat")
        authenticated = claims.get("auth_time")
        expires = claims.get("exp")
        uid = claims.get("sub")
        current = int(self._now())
        try:
            uid_size = len(uid.encode("utf-8")) if isinstance(uid, str) else 0
        except UnicodeError:
            uid_size = 0
        if (claims.get("aud") != self._project_id
                or claims.get("iss") != "https://securetoken.google.com/" + self._project_id
                or not 0 < uid_size <= 128
                or not all(_integer(value) for value in (issued, authenticated, expires))
                or not 0 < authenticated <= issued <= current < expires
                or issued >= expires):
            raise AuthRejected("Invalid Firebase ID token")
        return AuthenticatedIdentity(uid, issued, authenticated, expires)

    def verify(self, token: str) -> AuthenticatedIdentity:
        identity = self._signed_identity(token)
        body = json.dumps({"idToken": token}, separators=(",", ":")).encode("utf-8")
        response = self._request(
            "POST", self._lookup_url,
            {"Accept": "application/json", "Content-Type": "application/json"},
            body, MAX_LOOKUP_RESPONSE_BYTES,
        )
        if response.status in (400, 401, 403, 404):
            raise AuthRejected("Firebase account is not authorized")
        if response.status != 200:
            raise AuthUnavailable("Firebase Auth check unavailable")
        try:
            users = _json_object(response.body).get("users")
            if not isinstance(users, list) or len(users) != 1 or not isinstance(users[0], dict):
                raise ValueError("Invalid account lookup")
            account = users[0]
            valid_since = account.get("validSince")
            if (account.get("localId") != identity.uid
                    or account.get("disabled") is not False
                    or not isinstance(valid_since, str)
                    or re.fullmatch(r"[0-9]{1,20}", valid_since) is None
                    or identity.authenticated_at < int(valid_since)
                    or identity.issued_at < int(valid_since)):
                raise AuthRejected("Firebase account is not authorized")
        except AuthRejected:
            raise
        except (ValueError, TypeError):
            raise AuthUnavailable("Firebase Auth check unavailable") from None
        return identity


@lru_cache(maxsize=4)
def _default_bridge(project_id: str, web_api_key: str) -> FirebaseAuthBridge:
    return FirebaseAuthBridge(project_id, web_api_key)


def verify_firebase_id_token(
    token: str, *, project_id: str, web_api_key: str,
) -> str:
    """Blocking check of signature, current Firebase status and revocation.

    Returns only the verified UID. Invalid/revoked/disabled tokens raise
    ``AuthRejected``; unavailable Firebase checks raise ``AuthUnavailable``.
    Both derive from ``AuthenticationError`` and never include credentials.
    """
    return verify_firebase_identity(token, project_id=project_id, web_api_key=web_api_key).uid


def verify_firebase_identity(
    token: str, *, project_id: str, web_api_key: str,
) -> AuthenticatedIdentity:
    """Typed identity for resource authorization, with the same live checks."""
    try:
        bridge = _default_bridge(project_id, web_api_key)
    except ValueError:
        raise AuthUnavailable("Firebase Auth check unavailable") from None
    return bridge.verify(token)
