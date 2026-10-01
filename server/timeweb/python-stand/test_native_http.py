"""HTTP boundaries and bounded stand concurrency, using synthetic accounts."""
import io
import json
import socket
import threading
import time
import unittest
from contextlib import redirect_stderr
from types import SimpleNamespace
from unittest.mock import patch
from urllib.request import urlopen
from urllib.error import HTTPError

from app import create_app
from http_runtime import BoundedWSGIServer, make_bounded_server
from native_auth import NativeRejected, NativeRateLimited, NativeUnavailable

ENV = {"CLRS_API_DRAFT_ENABLED": "1", "CLRS_NATIVE_AUTH_ENABLED": "1",
       "CLRS_NATIVE_AUTH_WRITES_ENABLED": "1"}


def request(app, path, *, body=None, raw=None, method="POST", header=None, **changes):
    raw = json.dumps(body).encode() if raw is None and body is not None else raw
    raw = raw if raw is not None else b"{}"
    environ = {"REQUEST_METHOD": method, "PATH_INFO": path,
               "CONTENT_TYPE": "application/json", "CONTENT_LENGTH": str(len(raw)),
               "wsgi.input": io.BytesIO(raw), "REMOTE_ADDR": "127.0.0.1"}
    if header is not None:
        environ["HTTP_AUTHORIZATION"] = header
    environ.update(changes)
    result = {}
    def respond(status, headers):
        result.update(status=status, headers=dict(headers))
    result["raw"] = b"".join(app(environ, respond))
    result["body"] = json.loads(result["raw"])
    return result


class FakeService:
    def __init__(self):
        self.calls = []
        self.error = None
    def _call(self, name, value, peer, **kw):
        self.calls.append((name, value, peer, kw))
        if self.error:
            raise self.error("synthetic database secret and token")
        return {"uid": "synthetic-owner", "accessToken": "na1.synthetic"}
    def login(self, body, *, peer):
        return self._call("login", body, peer)
    def refresh(self, token, *, peer):
        return self._call("refresh", token, peer)
    def authorize(self, token, *, peer):
        self._call("authorize", token, peer)
        return SimpleNamespace(uid="synthetic-owner")
    def logout(self, token, *, peer, all_sessions):
        self._call("logout", token, peer, all_sessions=all_sessions)
        return {"loggedOut": True}


class NativeHttpTest(unittest.TestCase):
    def setUp(self):
        self.service = FakeService()
        self.profiles = []
        def forbidden(*args, **kwargs):
            self.fail("Native identity was passed to Google verifier")
        def profile(uid, **kw):
            self.profiles.append(uid)
            return {"uid": uid}
        self.app = create_app(env=ENV, native_service_factory=lambda env: self.service,
                              verify_token=forbidden, profile_reader=profile)

    def test_default_off_modes_do_not_construct_service_or_write(self):
        for env in ({"CLRS_API_DRAFT_ENABLED": "1"},
                    {**ENV, "CLRS_NATIVE_AUTH_WRITES_ENABLED": "0"},
                    {"CLRS_STAGING_SMOKE_ENABLED": "1"}):
            app = create_app(env=env, native_service_factory=lambda env: self.fail("Constructed"))
            self.assertEqual(request(app, "/v1/auth/login")["status"], "404 Not Found")
            if "CLRS_API_DRAFT_ENABLED" in env:
                self.assertEqual(request(app, "/v1/me/profile", method="GET",
                                         header="Bearer na1.synthetic")["status"], "401 Unauthorized")

    def test_login_refresh_logout_explicit_contract_and_socket_peer(self):
        login = {"email": "synthetic@example.test", "password": " synthetic ", "deviceId": "test-device"}
        response = request(self.app, "/v1/auth/login", body=login,
                           HTTP_X_FORWARDED_FOR="attacker-chosen")
        self.assertEqual(response["status"], "200 OK")
        self.assertEqual(response["headers"]["Cache-Control"], "no-store")
        self.assertEqual(self.service.calls[-1], ("login", login, "127.0.0.1", {}))
        request(self.app, "/v1/auth/refresh", body={"refreshToken": "nr1.synthetic"})
        self.assertEqual(self.service.calls[-1][1], "nr1.synthetic")
        response = request(self.app, "/v1/auth/logout", body={"allSessions": True}, header="Bearer na1.synthetic")
        self.assertEqual(response["body"], {"loggedOut": True})
        self.assertEqual(self.service.calls[-1][-1], {"all_sessions": True})

    def test_native_profile_uses_only_confirmed_identity_never_fallback(self):
        response = request(self.app, "/v1/me/profile", method="GET", header="Bearer na1.synthetic")
        self.assertEqual(response["body"], {"profile": {"uid": "synthetic-owner"}})
        self.assertEqual(self.profiles, ["synthetic-owner"])
        self.service.error = NativeRejected
        self.assertEqual(request(self.app, "/v1/me/profile", method="GET",
                                 header="Bearer na1.invalid")["status"], "401 Unauthorized")
        self.assertEqual(self.profiles, ["synthetic-owner"])

    def test_body_bounds_and_wrong_contract_fail_before_service(self):
        good = {"email": "a@b.test", "password": "test", "deviceId": "test"}
        cases = [{"CONTENT_LENGTH": "8193"}, {"CONTENT_LENGTH": "-1"},
                 {"CONTENT_LENGTH": ""}, {"CONTENT_LENGTH": "0000001"},
                 {"CONTENT_LENGTH": "9", "raw": b"{}"},
                 {"CONTENT_TYPE": "text/plain"}, {"HTTP_TRANSFER_ENCODING": "chunked"},
                 {"QUERY_STRING": "targetUid=other"},
                 {"raw": b'{"email":"a","email":"b","password":"p","deviceId":"d"}'},
                 {"raw": b"\xff"}, {"raw": b"[]"},
                 {"body": {**good, "targetUid": "other"}}]
        for changes in cases:
            with self.subTest(changes=list(changes)):
                response = request(self.app, "/v1/auth/login", **({"body": good} | changes))
                self.assertEqual(response["status"], "400 Bad Request")
        self.assertEqual(self.service.calls, [])
        for body in ({}, {"allSessions": 1}, {"allSessions": False, "uid": "other"}):
            self.assertEqual(request(self.app, "/v1/auth/logout", body=body,
                                     header="Bearer na1.synthetic")["status"], "400 Bad Request")
        self.assertEqual(self.service.calls, [])

    def test_query_token_and_malformed_authorization_are_rejected(self):
        response = request(self.app, "/v1/me/profile", method="GET",
                           QUERY_STRING="accessToken=na1.synthetic", header="Bearer na1.synthetic")
        self.assertEqual(response["status"], "400 Bad Request")
        for header in (None, "Bearer ", "Bearer na1.\nsecret", "Bearer na1.\tsecret", "Basic synthetic"):
            self.assertEqual(request(self.app, "/v1/me/profile", method="GET", header=header)["status"], "401 Unauthorized")
        self.assertEqual(self.service.calls, [])

    def test_errors_are_generic_and_rate_limit_explicit(self):
        for error, status in ((NativeRejected, "401 Unauthorized"),
                              (NativeRateLimited, "429 Too Many Requests"),
                              (NativeUnavailable, "503 Service Unavailable"),
                              (RuntimeError, "503 Service Unavailable")):
            self.service.error = error
            response = request(self.app, "/v1/auth/refresh", body={"refreshToken": "nr1.synthetic"})
            self.assertEqual(response["status"], status)
            self.assertNotIn(b"synthetic", response["raw"])
            self.assertNotIn(b"secret", response["raw"])
            if error is NativeRateLimited:
                self.assertEqual(response["headers"]["Retry-After"], "60")
        def broken(env):
            raise NativeUnavailable("secret")
        app = create_app(env=ENV, native_service_factory=broken)
        self.assertEqual(request(app, "/v1/auth/login")["status"], "503 Service Unavailable")
        self.assertEqual(request(self.app, "/v1/auth/login", method="GET")["status"], "405 Method Not Allowed")


class RuntimeTest(unittest.TestCase):
    def test_watchdog_start_failure_releases_socket_and_worker_slot(self):
        class FailedTimer:
            daemon = False
            cancelled = False
            def start(self): raise RuntimeError("No thread resources")
            def cancel(self): self.cancelled = True
        timer = FailedTimer()
        server = make_bounded_server("127.0.0.1", 0, lambda *args: [])
        closed = []; server.shutdown_request = lambda request: closed.append(request)
        self.assertTrue(server._slots.acquire(False))
        peer = object()
        try:
            with patch("http_runtime.threading.Timer", return_value=timer):
                server.process_request_thread(peer, ("127.0.0.1", 0))
            self.assertEqual(closed, [peer])
            self.assertTrue(timer.cancelled)
            acquired = []
            while server._slots.acquire(False): acquired.append(True)
            self.assertEqual(len(acquired), server.MAX_WORKERS)
            for _ in acquired: server._slots.release()
        finally:
            server.server_close()

    def test_absolute_deadline_releases_worker_despite_continuous_drip(self):
        def app(environ, respond):
            respond("200 OK", [("Content-Length", "2")]); return [b"ok"]
        with patch.object(BoundedWSGIServer, "MAX_WORKERS", 1), \
                patch.object(BoundedWSGIServer, "SOCKET_TIMEOUT_SECONDS", .2), \
                patch.object(BoundedWSGIServer, "REQUEST_DEADLINE_SECONDS", .3):
            server = make_bounded_server("127.0.0.1", 0, app)
        server.SOCKET_TIMEOUT_SECONDS = .2
        server.REQUEST_DEADLINE_SECONDS = .3
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        peer = socket.create_connection(server.server_address, timeout=1)
        peer.sendall(b"GET /incomplete HTTP/1.1\r\nHost: test\r\nX-Drip: ")
        stop = threading.Event()
        def drip():
            while not stop.wait(.02):
                try: peer.sendall(b"a")
                except OSError: return
        dripper = threading.Thread(target=drip, daemon=True); dripper.start()
        try:
            time.sleep(.1)
            # Deadline begins when worker starts; hold the short constants
            # until that worker has completed, rather than only construction.
            recovered = False
            end = time.monotonic() + 1.2
            while time.monotonic() < end:
                try:
                    with urlopen(f"http://127.0.0.1:{server.server_port}/healthz", timeout=.4) as response:
                        recovered = response.read() == b"ok"
                        if recovered: break
                except HTTPError as error:
                    self.assertEqual(error.code, 503)
                time.sleep(.02)
            self.assertTrue(recovered, "Absolute deadline failed to release the occupied slot")
        finally:
            stop.set(); peer.close(); dripper.join(1)
            server.shutdown(); server.server_close(); thread.join(1)

    def test_unexpected_wsgi_exception_is_not_logged(self):
        def broken(environ, respond):
            raise RuntimeError("synthetic sensitive database material")
        errors = io.StringIO()
        with redirect_stderr(errors):
            server = make_bounded_server("127.0.0.1", 0, broken)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                with self.assertRaises(HTTPError) as caught:
                    urlopen(f"http://127.0.0.1:{server.server_port}/", timeout=1)
                self.assertNotIn(b"sensitive", caught.exception.read())
            finally:
                server.shutdown(); server.server_close(); thread.join(1)
        self.assertNotIn("sensitive", errors.getvalue())
        self.assertNotIn("Traceback", errors.getvalue())

    def test_slow_request_does_not_block_health_and_threads_release(self):
        entered = threading.Event(); finish = threading.Event()
        def app(environ, respond):
            if environ["PATH_INFO"] == "/slow":
                entered.set(); finish.wait(3)
            respond("200 OK", [("Content-Length", "2")])
            return [b"ok"]
        server = make_bounded_server("127.0.0.1", 0, app)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        completed = []
        def slow():
            with urlopen(base + "/slow", timeout=4) as response:
                completed.append(response.read())
        worker = threading.Thread(target=slow, daemon=True); worker.start()
        try:
            self.assertTrue(entered.wait(2))
            with urlopen(base + "/healthz", timeout=1) as response:
                self.assertEqual(response.read(), b"ok")
            finish.set(); worker.join(2)
            self.assertEqual(completed, [b"ok"])
        finally:
            finish.set(); server.shutdown(); server.server_close(); thread.join(2)

    def test_worker_saturation_returns_complete_bounded_503_response(self):
        class Connection:
            def settimeout(self, value): self.timeout = value
            def sendall(self, value): self.response = value
        server = make_bounded_server("127.0.0.1", 0, lambda *args: [])
        connection = Connection(); closed = []
        server.shutdown_request = lambda request: closed.append(request)
        for _ in range(BoundedWSGIServer.MAX_WORKERS):
            self.assertTrue(server._slots.acquire(False))
        try:
            server.process_request(connection, ("127.0.0.1", 0))
            headers, body = connection.response.split(b"\r\n\r\n", 1)
            self.assertIn(b"503 Service Unavailable", headers)
            self.assertIn(b"Content-Length: " + str(len(body)).encode(), headers)
            self.assertEqual(json.loads(body), {"error": "service_unavailable"})
            self.assertEqual(closed, [connection])
        finally:
            for _ in range(BoundedWSGIServer.MAX_WORKERS):
                server._slots.release()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
