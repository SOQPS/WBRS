"""Offline Firebase Auth bridge tests with disposable synthetic RSA keys."""

import base64
from datetime import datetime, timedelta, timezone
import json
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID

from auth_bridge import (
    AuthenticationError, AuthRejected, AuthUnavailable, FirebaseAuthBridge,
    HttpResponse, LOOKUP_URL, X509_URL, verify_firebase_id_token,
)


NOW = 1_750_000_000
PROJECT = "demo-clrs-local"
API_KEY = "synthetic-api-key"
UID = "synthetic-user"


def encoded(value):
    raw = json.dumps(value, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


class AuthBridgeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "synthetic-test-only")])
        current = datetime.now(timezone.utc)
        certificate = (
            x509.CertificateBuilder()
            .subject_name(name).issuer_name(name)
            .public_key(cls.key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(current - timedelta(days=1))
            .not_valid_after(current + timedelta(days=1))
            .sign(cls.key, hashes.SHA256())
        )
        cls.pem = certificate.public_bytes(serialization.Encoding.PEM).decode("ascii")

    def setUp(self):
        self.calls = []
        self.account = {"localId": UID, "disabled": False, "validSince": str(NOW - 300)}
        self.cert_status = 200
        self.lookup_status = 200
        self.raise_on_lookup = False
        self.cache_control = "public, max-age=60"

        def transport(method, url, headers, body, timeout):
            self.calls.append((method, url, headers, body, timeout))
            if method == "GET" and url == X509_URL:
                return HttpResponse(
                    self.cert_status,
                    {"Cache-Control": self.cache_control},
                    json.dumps({"synthetic-kid": self.pem}).encode("utf-8"),
                )
            if method == "POST" and url == LOOKUP_URL + "?key=" + API_KEY:
                if self.raise_on_lookup:
                    raise RuntimeError("synthetic secret in provider exception")
                return HttpResponse(
                    self.lookup_status, {},
                    json.dumps({"users": [self.account]}).encode("utf-8"),
                )
            raise AssertionError("Unexpected external request")

        self.bridge = FirebaseAuthBridge(
            PROJECT, API_KEY, transport=transport, now=lambda: NOW,
        )

    def token(self, patch=None, header=None, key=None):
        claims = {
            "aud": PROJECT,
            "iss": "https://securetoken.google.com/" + PROJECT,
            "sub": UID,
            "exp": NOW + 3600,
            "iat": NOW - 30,
            "auth_time": NOW - 60,
        }
        claims.update(patch or {})
        head = header or {"alg": "RS256", "kid": "synthetic-kid", "typ": "JWT"}
        signing_input = (encoded(head) + "." + encoded(claims)).encode("ascii")
        signature = (key or self.key).sign(
            signing_input, padding.PKCS1v15(), hashes.SHA256(),
        )
        return signing_input.decode("ascii") + "." + base64.urlsafe_b64encode(
            signature,
        ).rstrip(b"=").decode("ascii")

    def test_valid_token_checks_current_account_and_returns_only_identity(self):
        token = self.token()
        identity = self.bridge.verify(token)
        self.assertEqual(identity.uid, UID)
        self.assertEqual(identity.authenticated_at, NOW - 60)
        self.assertEqual([call[0] for call in self.calls], ["GET", "POST"])
        self.assertEqual(json.loads(self.calls[1][3]), {"idToken": token})
        self.assertEqual(self.calls[1][2]["Content-Type"], "application/json")
        self.assertTrue(self.calls[1][1].startswith("https://"))
        self.assertLessEqual(self.calls[1][4], 5)

    def test_public_blocking_function_returns_uid_and_exposes_one_error_base(self):
        with patch("auth_bridge._default_bridge", return_value=self.bridge):
            self.assertEqual(verify_firebase_id_token(
                self.token(), project_id=PROJECT, web_api_key=API_KEY,
            ), UID)
        self.assertTrue(issubclass(AuthRejected, AuthenticationError))
        self.assertTrue(issubclass(AuthUnavailable, AuthenticationError))

    def test_lookup_is_per_request_even_when_signing_keys_are_cached(self):
        token = self.token()
        self.bridge.verify(token)
        self.bridge.verify(token)
        self.assertEqual([call[0] for call in self.calls], ["GET", "POST", "POST"])

    def test_disabled_wrong_uid_and_revoked_session_fail_closed(self):
        token = self.token()
        for change in (
            {"disabled": True},
            {"localId": "another-user"},
            {"validSince": str(NOW - 10)},
            {"validSince": None},
        ):
            with self.subTest(change=change):
                self.account = {"localId": UID, "disabled": False,
                                "validSince": str(NOW - 300), **change}
                with self.assertRaises(AuthRejected):
                    self.bridge.verify(token)

    def test_equal_valid_since_boundary_is_accepted(self):
        self.account["validSince"] = str(NOW - 60)
        self.assertEqual(self.bridge.verify(self.token()).uid, UID)

    def test_bad_claims_and_signature_never_reach_account_lookup(self):
        bad_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        candidates = [
            self.token({"aud": "other-project"}),
            self.token({"iss": "https://securetoken.google.com/other-project"}),
            self.token({"exp": NOW}),
            self.token({"iat": NOW + 1}),
            self.token({"auth_time": NOW + 1}),
            self.token({"sub": ""}),
            self.token(header={"alg": "none", "kid": "synthetic-kid"}),
            self.token(key=bad_key),
        ]
        for token in candidates:
            with self.subTest(token=token[:12]):
                self.calls.clear()
                with self.assertRaises(AuthRejected):
                    self.bridge.verify(token)
                self.assertNotIn("POST", [call[0] for call in self.calls])

    def test_lookup_errors_and_provider_failures_never_authorize(self):
        token = self.token()
        self.lookup_status = 403
        with self.assertRaises(AuthRejected):
            self.bridge.verify(token)
        self.lookup_status = 503
        with self.assertRaises(AuthUnavailable):
            self.bridge.verify(token)
        self.lookup_status = 200
        self.raise_on_lookup = True
        with self.assertRaises(AuthUnavailable) as caught:
            self.bridge.verify(token)
        self.assertNotIn(token, str(caught.exception))
        self.assertNotIn(API_KEY, str(caught.exception))
        self.assertNotIn("synthetic secret", str(caught.exception))

    def test_certificate_failure_and_unknown_key_fail_closed(self):
        token = self.token()
        self.cert_status = 503
        with self.assertRaises(AuthUnavailable):
            self.bridge.verify(token)
        self.cert_status = 200
        unknown = self.token(header={"alg": "RS256", "kid": "unknown"})
        with self.assertRaises(AuthRejected):
            self.bridge.verify(unknown)

    def test_unknown_kid_does_not_refetch_unexpired_certificates(self):
        self.bridge.verify(self.token())
        self.calls.clear()
        unknown = self.token(header={"alg": "RS256", "kid": "unknown"})
        with self.assertRaises(AuthRejected):
            self.bridge.verify(unknown)
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
