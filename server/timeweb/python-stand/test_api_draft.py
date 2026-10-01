"""Offline authorization and SQL-boundary checks for the isolated draft API."""

import json
import os
import ssl
import tempfile
import unittest
from unittest.mock import patch

from app import create_app
from auth_bridge import AuthRejected, AuthUnavailable
from profile_store import (
    AccountUnavailable, BUNDLED_CA_FILE, DatabaseUnavailable, PROFILE_QUERY,
    PROBE_QUERY, _database_config, probe_database, read_own_profile,
)


BASE_ENV = {
    "CLRS_API_DRAFT_ENABLED": "1",
    "FIREBASE_PROJECT_ID": "demo-clrs-local",
    "FIREBASE_WEB_API_KEY": "synthetic-api-key",
}


def request(application, path, *, method="GET", authorization=None):
    result = {}

    def respond(status, headers):
        result["status"] = status
        result["headers"] = dict(headers)

    environ = {"REQUEST_METHOD": method, "PATH_INFO": path}
    if authorization is not None:
        environ["HTTP_AUTHORIZATION"] = authorization
    result["body"] = b"".join(application(environ, respond))
    return result


class DraftApiTest(unittest.TestCase):
    def test_smoke_mode_exposes_no_api_and_never_invokes_auth(self):
        def forbidden(*args, **kwargs):
            self.fail("Data or auth was invoked in smoke mode")

        application = create_app(
            env={"CLRS_STAGING_SMOKE_ENABLED": "1"},
            verify_token=forbidden, profile_reader=forbidden,
        )
        self.assertEqual(request(application, "/healthz")["status"], "200 OK")
        self.assertEqual(request(application, "/readyz")["status"], "503 Service Unavailable")
        self.assertEqual(request(application, "/v1/me/profile")["status"], "404 Not Found")
        self.assertEqual(request(application, "/v1/me/profile", method="POST")["status"], "404 Not Found")

    def test_conflicting_flags_fail_closed(self):
        application = create_app(env={**BASE_ENV, "CLRS_STAGING_SMOKE_ENABLED": "1"})
        self.assertEqual(request(application, "/healthz")["status"], "503 Service Unavailable")
        self.assertEqual(request(application, "/v1/me/profile")["status"], "404 Not Found")

    def test_api_not_ready_and_no_arbitrary_sql_or_admin_routes(self):
        application = create_app(env=BASE_ENV)
        ready = request(application, "/readyz")
        self.assertEqual(ready["status"], "503 Service Unavailable")
        self.assertEqual(json.loads(ready["body"]), {
            "state": "migration_incomplete", "database_connected": False,
        })
        for route in ("/query", "/tables", "/sql/execute", "/admin", "/v1/profiles/other"):
            self.assertEqual(request(application, route)["status"], "404 Not Found")
        self.assertEqual(request(application, "/v1/me/profile", method="POST")["status"], "404 Not Found")
        self.assertEqual(request(application, "/healthz", method="HEAD")["body"], b"")

    def test_readyz_reports_probe_without_claiming_migration_complete(self):
        calls = []
        def probe(*, env):
            calls.append(env)
            return True
        application = create_app(env=BASE_ENV, database_probe=probe)
        ready = request(application, "/readyz")
        self.assertEqual(ready["status"], "503 Service Unavailable")
        self.assertEqual(json.loads(ready["body"]), {
            "state": "migration_incomplete", "database_connected": True,
        })
        self.assertEqual(calls, [BASE_ENV])
        self.assertEqual(request(application, "/readyz", method="HEAD")["body"], b"")
        smoke = create_app(env={"CLRS_STAGING_SMOKE_ENABLED": "1"},
                           database_probe=lambda **kw: self.fail("DB queried in smoke mode"))
        self.assertFalse(json.loads(request(smoke, "/readyz")["body"])["database_connected"])

    def test_missing_configuration_and_bad_header_never_reach_profile(self):
        def forbidden(*args, **kwargs):
            self.fail("Unexpected auth or DB access")
        self.assertEqual(
            request(create_app(env={"CLRS_API_DRAFT_ENABLED": "1"},
                               verify_token=forbidden, profile_reader=forbidden),
                    "/v1/me/profile", authorization="Bearer synthetic")["status"],
            "503 Service Unavailable",
        )
        application = create_app(env=BASE_ENV, verify_token=forbidden, profile_reader=forbidden)
        for header in (None, "", "Basic synthetic", "Bearer ", "Bearer a b"):
            response = request(application, "/v1/me/profile", authorization=header)
            self.assertEqual(response["status"], "401 Unauthorized")
            self.assertEqual(response["headers"]["WWW-Authenticate"], "Bearer")

    def test_authenticated_uid_is_only_profile_key_and_response_is_minimal(self):
        calls = []
        def verify(token, *, project_id, web_api_key):
            calls.append(("verify", token, project_id, web_api_key))
            return "synthetic-owner"
        def read(uid, *, env):
            calls.append(("read", uid))
            return {"uid": uid, "fullName": "Synthetic", "city": None}
        application = create_app(env=BASE_ENV, verify_token=verify, profile_reader=read)
        response = request(application, "/v1/me/profile", authorization="Bearer synthetic-token")
        self.assertEqual(response["status"], "200 OK")
        self.assertEqual(response["headers"]["Cache-Control"], "no-store")
        self.assertEqual(json.loads(response["body"]), {
            "profile": {"uid": "synthetic-owner", "fullName": "Synthetic", "city": None},
        })
        self.assertEqual(calls, [
            ("verify", "synthetic-token", "demo-clrs-local", "synthetic-api-key"),
            ("read", "synthetic-owner"),
        ])

    def test_failed_auth_or_storage_never_leaks_token_or_internal_detail(self):
        def rejected(*args, **kwargs):
            raise AuthRejected("synthetic-token secret")
        def unavailable(*args, **kwargs):
            raise AuthUnavailable("synthetic-token secret")
        for verify, expected in ((rejected, "401 Unauthorized"), (unavailable, "503 Service Unavailable")):
            response = request(
                create_app(env=BASE_ENV, verify_token=verify),
                "/v1/me/profile", authorization="Bearer synthetic-token",
            )
            self.assertEqual(response["status"], expected)
            self.assertNotIn(b"synthetic-token", response["body"])
        for error, expected in ((AccountUnavailable, "404 Not Found"),
                                (DatabaseUnavailable, "503 Service Unavailable")):
            def read(uid, *, env):
                raise error("synthetic secret")
            response = request(
                create_app(env=BASE_ENV, verify_token=lambda *a, **kw: "synthetic-owner",
                           profile_reader=read),
                "/v1/me/profile", authorization="Bearer synthetic-token",
            )
            self.assertEqual(response["status"], expected)
            self.assertNotIn(b"synthetic secret", response["body"])


class ProfileStoreTest(unittest.TestCase):
    def setUp(self):
        self.ca = tempfile.NamedTemporaryFile()
        self.env = {
            "CLRS_DB_URL": "mysql://clrs_reader:synthetic-pass@db.example.test:3306/clrs_staging?sslmode=verify-full",
            "CLRS_DB_CA_FILE": self.ca.name,
        }

    def tearDown(self):
        self.ca.close()

    def test_query_is_fixed_parameterized_self_only_and_connection_closes(self):
        calls = []
        class Cursor:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def execute(self, sql, args): calls.append((sql, args))
            def fetchone(self): return (0, "active", "Synthetic", "XX", "City", "Group")
        class Connection:
            def cursor(self): return Cursor()
            def close(self): calls.append("closed")
        def connect(**config):
            self.assertEqual(config["host"], "db.example.test")
            self.assertEqual(config["database"], "clrs_staging")
            self.assertTrue(config["ssl"].check_hostname)
            self.assertEqual(config["ssl"].verify_mode, ssl.CERT_REQUIRED)
            return Connection()
        with patch("profile_store.ssl.create_default_context", return_value=ssl.create_default_context()):
            profile = read_own_profile("synthetic-owner", env=self.env, connect=connect)
        self.assertEqual(profile, {
            "uid": "synthetic-owner", "fullName": "Synthetic",
            "country": "XX", "city": "City", "group": "Group",
        })
        self.assertEqual(calls, [(PROFILE_QUERY, ("synthetic-owner",)), "closed"])
        self.assertNotIn("synthetic-owner", PROFILE_QUERY)
        self.assertNotIn("auth_credentials", PROFILE_QUERY)

    def test_disabled_deleted_or_missing_profile_rejected(self):
        class Cursor:
            def __init__(self, row): self.row = row
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def execute(self, *args): pass
            def fetchone(self): return self.row
        class Connection:
            def __init__(self, row): self.row = row
            def cursor(self): return Cursor(self.row)
            def close(self): pass
        with patch("profile_store.ssl.create_default_context", return_value=ssl.create_default_context()):
            for row in (None, (1, "active", "Synthetic", None, None, None),
                        (0, "deleted", "Synthetic", None, None, None),
                        (0, "active", None, None, None, None)):
                with self.subTest(row=row), self.assertRaises(AccountUnavailable):
                    read_own_profile("synthetic-owner", env=self.env,
                                     connect=lambda **kw: Connection(row))

    def test_requires_exact_staging_database_ca_and_verified_tls(self):
        bad_urls = (
            "mysql://u:p@db.example.test/default_db?sslmode=verify-full",
            "mysql://u:p@db.example.test/clrs_staging",
            "mysql://u:p@127.0.0.1/clrs_staging?sslmode=verify-full",
            "mysql://u:p@localhost/clrs_staging?sslmode=verify-full",
            "mysql://u:p@db.example.test/clrs_staging?sslmode=require",
        )
        for url in bad_urls:
            with self.subTest(url=url), self.assertRaises(DatabaseUnavailable):
                read_own_profile("synthetic-owner",
                    env={**self.env, "CLRS_DB_URL": url},
                    connect=lambda **kw: self.fail("Connected with invalid config"))
        with self.assertRaises(DatabaseUnavailable):
            read_own_profile("synthetic-owner",
                env={**self.env, "CLRS_DB_CA_FILE": "/nonexistent/synthetic-ca.pem"},
                connect=lambda **kw: self.fail("Connected without CA"))

    def test_bundled_timeweb_ca_is_default_without_relaxing_tls(self):
        env = {"CLRS_DB_URL": self.env["CLRS_DB_URL"]}
        config = _database_config(env)
        self.assertTrue(os.path.isfile(BUNDLED_CA_FILE))
        self.assertTrue(config["ssl"].check_hostname)
        self.assertEqual(config["ssl"].verify_mode, ssl.CERT_REQUIRED)
        with self.assertRaises(DatabaseUnavailable):
            _database_config({**env, "CLRS_DB_CA_FILE": ""})

    def test_probe_selects_constant_only_and_closes_connection(self):
        calls = []
        class Cursor:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def execute(self, sql): calls.append(("query", sql))
            def fetchone(self): return (1,)
        class Connection:
            def cursor(self): return Cursor()
            def close(self): calls.append("closed")
        with patch("profile_store.ssl.create_default_context", return_value=ssl.create_default_context()):
            self.assertTrue(probe_database(env=self.env,
                                           connect=lambda **kw: Connection()))
        self.assertEqual(calls, [("query", PROBE_QUERY), "closed"])
        self.assertEqual(PROBE_QUERY, "SELECT 1")

    def test_probe_rejects_invalid_configuration_before_connect(self):
        forbidden = lambda **kw: self.fail("Connected with invalid configuration")
        for env in ({}, {"CLRS_DB_URL": "mysql://u:p@localhost/clrs_staging?sslmode=verify-full"},
                    {**self.env, "CLRS_DB_CA_FILE": "/nonexistent/synthetic-ca.pem"}):
            with self.subTest(env_keys=sorted(env)):
                self.assertFalse(probe_database(env=env, connect=forbidden))


if __name__ == "__main__":
    unittest.main()
