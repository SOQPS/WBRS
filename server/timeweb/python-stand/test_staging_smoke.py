import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("clrs_staging_smoke", Path(__file__).with_name("app.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def request(path, method="GET"):
    result = {}

    def respond(status, headers):
        result["status"] = status
        result["headers"] = dict(headers)

    result["body"] = b"".join(MODULE.app({"REQUEST_METHOD": method, "PATH_INFO": path}, respond))
    return result


class StagingSmokeTest(unittest.TestCase):
    def test_health_is_inert(self):
        for path in ("/", "/health", "/healthz"):
            response = request(path)
            self.assertEqual(response["status"], "200 OK")
            self.assertIn(b"smoke_only", response["body"])
            self.assertEqual(response["headers"]["Cache-Control"], "no-store")

    def test_no_data_plane_is_ready(self):
        self.assertEqual(request("/readyz")["status"], "503 Service Unavailable")
        for path in ("/sql/execute", "/query", "/tables", "/users", "/chats", "/upload-photo"):
            self.assertEqual(request(path)["status"], "404 Not Found")
            self.assertEqual(request(path, "POST")["status"], "404 Not Found")

    def test_default_mode_has_no_data_routes(self):
        for path in ("/v1/me/profile", "/v1/profiles/other", "/admin", "/sql/execute"):
            self.assertEqual(request(path)["status"], "404 Not Found")


if __name__ == "__main__":
    unittest.main()
