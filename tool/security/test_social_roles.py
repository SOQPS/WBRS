"""Local-only Firestore rules smoke test; never contacts production Firebase."""

import json
import urllib.error
import urllib.request


PROJECT = "demo-clrs-roles"
AUTH = "http://127.0.0.1:9095/identitytoolkit.googleapis.com/v1"
DB = f"http://127.0.0.1:8085/v1/projects/{PROJECT}/databases/(default)/documents"


def request(url, body, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    payload = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=payload, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def fields(**values):
    return {"fields": {key: {"stringValue": value} for key, value in values.items()}}


status, account = request(
    AUTH + "/accounts:signUp?key=local-demo",
    {"email": "reader@example.test", "password": "local-demo-password", "returnSecureToken": True},
)
assert status == 200, account
uid, token = account["localId"], account["idToken"]

status, _ = request(
    DB + f"/author_requests?documentId={uid}",
    fields(uid=uid, fullName="Reader", requestedRole="author", status="pending"),
    token,
)
assert status == 200, f"An ordinary user must be able to request author rights: {status}"

status, _ = request(
    DB + f"/author_grants?documentId={uid}",
    fields(uid=uid, status="approved"),
    token,
)
assert status == 403, f"An ordinary user issued their own author grant: {status}"

status, _ = request(
    DB + "/posts?documentId=self-issue-attempt",
    fields(authorUid=uid, status="published"),
    token,
)
assert status == 403, f"An unapproved author published a post: {status}"

status, _ = request(
    DB + "/moderator_grants?documentId=other",
    fields(uid="other", status="approved"),
    token,
)
assert status == 403, f"An ordinary user issued a moderator grant: {status}"

print("PASS: role request allowed; self-grants and unapproved publication denied")
