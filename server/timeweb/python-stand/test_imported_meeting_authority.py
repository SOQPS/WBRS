"""New synthetic final-pack and actual read-store cases; no keys/network/SQL."""
import copy
from datetime import datetime, timezone
import hmac
import ssl
import unittest

from imported_meeting_authority import (load_imported_authority, source_fingerprint,
    digest, DOMAIN, POLICY, MAX_BYTES)
from runtime_imported_meetings import RuntimeImportedMeetingsService, imported_meetings_factory
from runtime_meetings import RuntimeMeetingsService, TRUSTED_POLICY, MEETING_FIELDS
from runtime_meeting_join import _target, _JoinFailure
from runtime_mutations import RuntimeUnavailable, RuntimeRejected, RuntimeInvalidRequest, canonical_json
from runtime_reads import RuntimeReadRejected
from legacy_conversation_payload import payload_digest
from test_runtime_meetings import (MeetingsDatabase, MeetingsConnection, MeetingsCursor,
                                  KEY, READ_ENV, MEETING_KEYS, MEMBER_KEYS)
from test_runtime_people import source
from test_runtime_mutations import store_for, STAMP, NOW

SIGNING_KEY = b"synthetic-final-pack-key-32-bytes!"
SHA = lambda digit: digit * 64


def root_payload(users=("actor", "peer"), kicked=()):
    s = lambda text: {"stringValue": text}
    return {"fields": {"name": s("Встреча"), "description": s("Описание"), "admin": s("peer"),
        "type": s("групповая"), "countryCode": s("RU"), "region": s("Москва"),
        "datetime": s("03.10.2026 19:15"),
        "users": {"arrayValue": {"values": [s(uid) for uid in users]}},
        "kicked": {"arrayValue": {"values": [s(uid) for uid in kicked]}}},
        "createTime": STAMP, "updateTime": STAMP}


def pack(db, ids=("m",), *, generation=SHA("1"), users=("actor", "peer"), kicked=()):
    entries = []
    for uid in ids:
        payload = root_payload(users, kicked); hashed = payload_digest(payload)
        db.add_meeting(uid, title="Встреча", description="Описание", createdAt=STAMP, legacy_raw=payload)
        row = db.state["meetings"][uid]
        for index, member_uid in enumerate(users):
            db.join(uid, member_uid, joinedAt=None, legacy_raw={"source_path": "meets/" + uid,
                "source_index": index, "source_field": "users", "source_payload_hash": hashed})
        entries.append({"meetingId": uid, "firebasePath": "meets/" + uid, "payloadSha256": hashed,
            "metadataReviewSha256": SHA("2"), "sourceContract": "reviewed-imported-meets-v1",
            "canonical": {field: row[field] for field in (*MEETING_FIELDS[:12], "localDatetime")},
            "users": list(users), "kicked": list(kicked), "missingKickedReviewed": False})
    tombstones = ["deleted-source"]
    final = [[entry["meetingId"], entry["payloadSha256"]] for entry in entries]
    binding = {"generation": generation, "sourceSha256": source_fingerprint(),
        "cohortSha256": digest({"meetings": entries, "tombstones": tombstones}), "policy": POLICY,
        "barrierSha256": SHA("3"), "finalDeltaSha256": SHA("4")}
    return {"v": 1, "kind": "imported-meeting-final-authority", "namespace": {
            "project": "chatapp-4e347", "database": "(default)", "collection": "meets"},
        "binding": binding, "barrier": {"enforced": True, "allWritersStopped": True, "verified": True,
            "receiptSha256": SHA("3"), "writerSetSha256": SHA("5"), "enforcementSha256": SHA("6"),
            "verifiedAt": STAMP, "generation": generation},
        "finalDelta": {"consistent": True, "final": True, "complete": True, "readbackVerified": True,
            "receiptSha256": SHA("4"), "barrierSha256": SHA("3"), "rootSetSha256": digest(final),
            "tombstonesSha256": digest(tombstones), "completedAt": STAMP},
        "issuedAt": STAMP, "finalRoots": final, "tombstones": tombstones, "meetings": entries}


def capability(body, *, expected=None, domain=DOMAIN):
    raw = canonical_json(body, max_bytes=MAX_BYTES)
    return load_imported_authority(raw, hmac.digest(SIGNING_KEY, domain + raw, "sha256"), SIGNING_KEY,
        reviewed_binding=body["binding"] if expected is None else expected,
        clock=lambda: datetime.fromtimestamp(NOW + 1, timezone.utc))


class ProofDatabase(MeetingsDatabase):
    def connect(self, **config):
        assert config["ssl"].verify_mode == ssl.CERT_REQUIRED and config["ssl"].check_hostname
        c = ProofConnection(self); self.connections.append(c); return c


class ProofConnection(MeetingsConnection):
    def cursor(self): return ProofCursor(self)


class ProofCursor(MeetingsCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split())
        member = sql.startswith("SELECT mm.meeting_id, mm.uid, CASE WHEN OCTET_LENGTH")
        root = sql.startswith("SELECT m.meeting_id, CASE WHEN OCTET_LENGTH")
        if not member and not root: return super().execute(statement, params)
        self.c.db.calls.append((sql, params))
        assert self.c.readonly and self.c.held and sql.endswith("FOR SHARE OF " + ("mm" if member else "m"))
        step = 4 if member else 2; assert params[-1] <= 32 and len(params) == step * params[-1] + 1
        self.rows = []
        for offset in range(0, len(params) - 1, step):
            uid = params[offset]; assert uid == params[offset + 1]
            if member:
                peer = params[offset + 2]; assert peer == params[offset + 3]
                row = self.c.state["meeting_members"].get((uid, peer))
                if row: self.rows.append((uid, peer, copy.deepcopy(row["legacy_raw"])))
            else:
                row = self.c.state["meetings"].get(uid)
                if row: self.rows.append((uid, copy.deepcopy(row["legacy_raw"])))
        self.rowcount = len(self.rows)
        if self.c.db.after_read: self.c.db.after_read("proofs", self.c)
        return self.rowcount


class ImportedAuthorityTests(unittest.TestCase):
    def setUp(self):
        self.db = ProofDatabase(); self.store = store_for(self.db); self.addCleanup(self.store.close)
        self.body = pack(self.db); self.reads = self.reader(self.body)

    def reader(self, body):
        return RuntimeImportedMeetingsService(self.store, KEY, authority=capability(body),
            reviewed_binding=body["binding"], clock=lambda: NOW)

    def detail(self, reader=None):
        return (reader or self.reads).meeting(self.db.identity, "m", access_token=self.db.access)

    def test_final_pack_flags_binding_domain_tombstones_and_schedule_refusals(self):
        mutations = [("barrier", key, False) for key in ("enforced", "allWritersStopped", "verified")]
        mutations += [("finalDelta", key, False) for key in ("consistent", "final", "complete", "readbackVerified")]
        mutations += [("finalDelta", "barrierSha256", SHA("9")), ("finalDelta", "rootSetSha256", SHA("9")),
                      ("finalDelta", "tombstonesSha256", SHA("9")), ("binding", "sourceSha256", SHA("9"))]
        for parent, key, value in mutations:
            with self.subTest(parent=parent, key=key):
                body = copy.deepcopy(self.body); body[parent][key] = value
                with self.assertRaises(RuntimeUnavailable): capability(body)
        for schedule in (None, "3.10.2026 19:15", "UTC"):
            body = copy.deepcopy(self.body); canon = body["meetings"][0]["canonical"]
            canon["localDatetime"] = None if schedule == "UTC" else schedule
            if schedule == "UTC": canon["startsAt"] = STAMP
            body["binding"]["cohortSha256"] = digest({"meetings": body["meetings"], "tombstones": body["tombstones"]})
            with self.assertRaises(RuntimeUnavailable): capability(body)
        expected = {**self.body["binding"], "generation": SHA("9")}
        with self.assertRaises(RuntimeUnavailable): capability(self.body, expected=expected)
        with self.assertRaises(RuntimeUnavailable): capability(self.body, domain=b"old-observation\0")
        with self.assertRaises(RuntimeUnavailable): load_imported_authority(b"x" * (MAX_BYTES + 1), b"x" * 32,
            SIGNING_KEY, reviewed_binding=self.body["binding"])
        body = copy.deepcopy(self.body); body["tombstones"] = ["m"]
        body["finalDelta"]["tombstonesSha256"] = digest(["m"])
        body["binding"]["cohortSha256"] = digest({"meetings": body["meetings"], "tombstones": ["m"]})
        with self.assertRaises(RuntimeUnavailable): capability(body)

    def test_actual_store_list_detail_roster_null_history_current_revision_and_redaction(self):
        self.db.state["meetings"]["m"]["revision"] = 8
        self.db.state["meeting_members"][("m", "actor")]["membershipRevision"] = 3
        before = copy.deepcopy(self.db.state)
        page = self.reads.meetings(self.db.identity, access_token=self.db.access)
        self.assertEqual(page["items"], [self.detail()["meeting"]])
        self.assertEqual(set(page["items"][0]), MEETING_KEYS)
        roster = self.reads.participants(self.db.identity, "m", access_token=self.db.access)
        self.assertEqual([item["uid"] for item in roster["items"]], ["actor", "peer"])
        self.assertTrue(all(item["joinedAt"] is None and set(item) == MEMBER_KEYS for item in roster["items"]))
        self.assertEqual(roster["items"][0]["membershipRevision"], 3)
        self.assertEqual(self.db.state, before)
        for private in (b"legacy_raw", b"payloadSha256", b"users", b"kicked", b"email", b"role", b"binding"):
            self.assertNotIn(private, canonical_json(page) + canonical_json(roster))
        self.assertTrue(all(c.readonly and c.closed and c.commits == 0 for c in self.db.connections))
        self.assertTrue(all(not sql.startswith(("INSERT", "UPDATE", "DELETE")) for sql, _ in self.db.calls))
        self.assertLess(max(len(calls) for calls in [self.db.calls]), 64)

    def test_raw_metadata_provenance_hidden_deleted_current_left_and_source_kick_refusals(self):
        initial = copy.deepcopy(self.db.state)
        for change in ("raw", "metadata", "member", "hidden", "deleted", "fake-joined"):
            with self.subTest(change=change):
                self.db.state = copy.deepcopy(initial)
                if change == "raw": self.db.state["meetings"]["m"]["legacy_raw"]["fields"]["name"] = {"stringValue": "Changed"}
                elif change == "metadata": self.db.state["meetings"]["m"]["title"] = "Changed"
                elif change == "member": self.db.state["meeting_members"][("m", "actor")]["legacy_raw"]["source_index"] = 1
                elif change == "hidden": self.db.state["profiles"]["peer"]["legacy_raw"] = source("peer", isUnVisible={"booleanValue": True})
                elif change == "deleted": self.db.state["meetings"]["m"]["deletedAt"] = STAMP
                elif change == "fake-joined": self.db.state["meeting_members"][("m", "actor")]["joinedAt"] = STAMP
                with self.assertRaises((RuntimeReadRejected, RuntimeUnavailable)): self.detail()
        self.db.state = copy.deepcopy(initial)
        self.db.state["meeting_members"][("m", "actor")]["leftAt"] = STAMP
        self.assertEqual([item["uid"] for item in self.reads.participants(self.db.identity, "m", access_token=self.db.access)["items"]], ["peer"])
        self.assertEqual(self.detail()["meeting"]["meetingId"], "m")
        body = pack(self.db, users=("peer",), kicked=("actor",)); self.db.state["meeting_members"].pop(("m", "actor"))
        with self.assertRaises(RuntimeReadRejected): self.detail(self.reader(body))

    def test_actor_swap_revoke_cursor_generation_and_member_state_change(self):
        body = pack(self.db, ids=("a", "b")); reads = self.reader(body)
        page = reads.meetings(self.db.identity, access_token=self.db.access, limit=1)
        self.assertIsNotNone(page["nextCursor"])
        identity_b, token_b = self.db.actor_b()
        with self.assertRaises(RuntimeInvalidRequest): reads.meetings(identity_b, access_token=token_b, limit=1, cursor=page["nextCursor"])
        changed = copy.deepcopy(body); changed["binding"]["generation"] = SHA("9"); changed["barrier"]["generation"] = SHA("9")
        with self.assertRaises(RuntimeInvalidRequest): self.reader(changed).meetings(self.db.identity,
            access_token=self.db.access, limit=1, cursor=page["nextCursor"])
        with self.assertRaises(RuntimeRejected): self.reads.meeting(self.db.identity, "m", access_token=token_b)
        self.db.after_read = lambda category, connection: connection.state["accounts"]["actor"].__setitem__(0, 1) if category == "proofs" else None
        with self.assertRaises(RuntimeRejected): self.detail()

    def test_factory_default_closed_and_imported_chat_mutation_guards_stay_closed(self):
        self.assertIsNone(imported_meetings_factory()(self.store, READ_ENV))
        cap = capability(self.body)
        with self.assertRaises(RuntimeUnavailable): imported_meetings_factory(cap)
        factory = imported_meetings_factory(cap, reviewed_binding=self.body["binding"])
        self.assertIsNone(factory(self.store, {**READ_ENV, "CLRS_RUNTIME_WRITES_ENABLED": "0"}))
        self.assertIsInstance(factory(self.store, READ_ENV), RuntimeImportedMeetingsService)
        for operation in (self.reads.messages, self.reads.archived_messages):
            with self.assertRaises(RuntimeReadRejected): operation(self.db.identity, "m", access_token=self.db.access)
        native = RuntimeMeetingsService(self.store, KEY, trusted_policy=TRUSTED_POLICY, clock=lambda: NOW)
        self.assertEqual(native.meetings(self.db.identity, access_token=self.db.access)["items"], [])
        def action(cursor, execute, uid):
            with self.assertRaises(_JoinFailure): _target(cursor, execute, uid, "m", datetime.fromtimestamp(NOW, timezone.utc), readonly=True)
            return {"denied": True}
        self.store.read_authenticated(self.db.identity, action, access_token=self.db.access)
        cap.require(self.body["binding"])
        before = cap.entry("m"); before["users"].clear()
        self.assertEqual(cap.entry("m")["users"], ["actor", "peer"])


if __name__ == "__main__": unittest.main()
