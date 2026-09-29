#!/usr/bin/env python3
"""Publish or roll back the narrow Storage write-auth containment rule.

Only release pointers and hashes are recorded. OAuth tokens never enter files
or command output. This is deliberately not the final per-user Storage policy.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

PROJECT = "chatapp-4e347"
ROOT = Path(__file__).resolve().parent
RULES = ROOT / "storage.auth-only-containment.rules"
AUDIT = ROOT / "production_storage_containment_2026-09-30.json"
API = "https://firebaserules.googleapis.com/v1/"


def token():
    result = subprocess.run(
        ["/opt/homebrew/bin/gcloud", "auth", "application-default", "print-access-token"],
        check=True, capture_output=True, text=True, timeout=20,
    )
    return result.stdout.strip()


def api(method, path, access_token, payload=None):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        API + path, data=body, method=method,
        headers={"Authorization": "Bearer " + access_token,
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Firebase Rules API {method} failed: HTTP {error.code}") from None


def current_release(access_token):
    data = api("GET", f"projects/{PROJECT}/releases", access_token)
    storage = [entry for entry in data.get("releases", [])
               if "/releases/firebase.storage/" in entry.get("name", "")]
    if len(storage) != 1:
        raise RuntimeError(f"Expected one Storage release, found {len(storage)}")
    return storage[0]


def save_audit(data):
    fd, temp_path = tempfile.mkstemp(prefix="storage-audit-", dir=ROOT)
    try:
        os.chmod(temp_path, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temp_path, AUDIT)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def patch_release(access_token, release_name, ruleset_name):
    return api("PATCH", release_name,
               access_token, {"release": {"name": release_name,
                                           "rulesetName": ruleset_name},
                              "updateMask": "rulesetName"})


def publish(access_token):
    before = current_release(access_token)
    old_ruleset = before["rulesetName"]
    old_source = api("GET", old_ruleset, access_token)["source"]["files"]
    if len(old_source) != 1:
        raise RuntimeError("Existing Storage rules have changed: multiple files")
    source = re.sub(r"//[^\n]*", "", old_source[0]["content"])
    if ("service firebase.storage" not in source
            or not re.search(r"allow\s+read\s*,\s*write\s*:\s*if\s+true\s*;", source)
            or len(re.findall(r"\ballow\b", source)) != 1):
        raise RuntimeError("Existing Storage rules changed; refusing to overwrite")
    candidate = RULES.read_text(encoding="utf-8")
    if "allow write: if request.auth != null;" not in candidate:
        raise RuntimeError("Containment source is unexpected")
    new = api("POST", f"projects/{PROJECT}/rulesets", access_token,
              {"source": {"files": [{"name": "storage.rules", "content": candidate}]}})
    audit = {
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "releaseName": before["name"],
        "previousRulesetName": old_ruleset,
        "newRulesetName": new["name"],
        "previousSourceSha256": hashlib.sha256(old_source[0]["content"].encode()).hexdigest(),
        "newSourceSha256": hashlib.sha256(candidate.encode()).hexdigest(),
        "status": "ruleset-created",
    }
    save_audit(audit)
    if current_release(access_token)["rulesetName"] != old_ruleset:
        raise RuntimeError("Storage release changed concurrently; no deployment performed")
    patch_release(access_token, before["name"], new["name"])
    if current_release(access_token)["rulesetName"] != new["name"]:
        raise RuntimeError("Release verification failed; inspect before retrying")
    audit["status"] = "published"
    save_audit(audit)
    print("Storage containment published; previous release saved for rollback.")
    print("release=" + before["name"])
    print("ruleset=" + new["name"])


def rollback(access_token):
    audit = json.loads(AUDIT.read_text(encoding="utf-8"))
    current = current_release(access_token)
    if current["name"] != audit["releaseName"] or current["rulesetName"] != audit["newRulesetName"]:
        raise RuntimeError("Release differs from recorded deployment; refusing rollback")
    patch_release(access_token, current["name"], audit["previousRulesetName"])
    if current_release(access_token)["rulesetName"] != audit["previousRulesetName"]:
        raise RuntimeError("Rollback verification failed")
    audit["status"] = "rolled-back"
    save_audit(audit)
    print("Previous Storage rules restored.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--apply", action="store_true")
    group.add_argument("--rollback", action="store_true")
    options = parser.parse_args()
    access_token = token()
    publish(access_token) if options.apply else rollback(access_token)
