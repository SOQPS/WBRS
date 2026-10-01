"""Scoped synthetic discovery tests. No real UID, archive, SQL or media IO."""
import copy
from decimal import Decimal
import json
import unittest

from legacy_conversation_discovery import (LegacyConversationDiscoveryService,
    CHAT_ORDER, MEETING_ORDER, _order, discovery_query)
from legacy_conversation_payload import document
from legacy_conversation_read import LegacyReadRejected, LegacyReadUnavailable
from test_legacy_conversation_read import (FakeConnection, FakeDatabase, KEY,
    NOW, PIN, SOURCE, STAMP, UID_A, UID_B, UID_X, array, enabled, identity, s)


class DiscoveryConnection(FakeConnection):
    def execute(self, sql, parameters=()):
        if "AS own_discovery" not in sql and "AS bounded_discovery" not in sql:
            return super().execute(sql, parameters)
        self.db.calls.append((sql, copy.deepcopy(parameters))); self.result = []
        collection = parameters[1].decode(); uid = parameters[2].decode()
        meeting = collection == "meets"
        candidates = []
        for item in self.db.documents.values():
            if item[1] != collection:
                continue
            payload = document(item[3]); fields = payload["fields"]
            if meeting:
                selected = fields.get("admin", {}).get("stringValue") == uid or s(uid) in fields.get("users", {}).get("arrayValue", {}).get("values", [])
            else:
                selected = any(fields.get(name, {}).get("stringValue") == uid for name in ["user1", "user2"])
            if selected:
                candidates.append(item)
        if "AS bounded_discovery" in sql:
            self.result = [(min(len(candidates), parameters[-1]),)]
            if self.db.count_override is not None:
                self.result = [(self.db.count_override,)]
            return
        for item in candidates:
            try:
                order, _ = _order(document(item[3]), meeting)
            except Exception:
                order = 0 if not meeting else -1  # Driver returns row; core validates.
            if len(parameters) == 8 and (order, item[2].encode()) >= (int(parameters[4]), parameters[6]):
                continue
            self.result.append((*item, Decimal(order)))
        self.result.sort(key=lambda item: (item[5], item[2].encode()), reverse=True)
        self.result = self.result[:parameters[-1]]
        if self.db.alter_result:
            self.result = self.db.alter_result(self.result)


class DiscoveryDatabase(FakeDatabase):
    def __init__(self):
        super().__init__(); self.count_override = None

    def connect(self, **config):
        self.configs.append(config)
        connection = DiscoveryConnection(self); self.connections.append(connection)
        return connection

    def service(self, *, env=None, clock=None):
        return LegacyConversationDiscoveryService(env or enabled(), KEY, connect=self.connect,
            clock=clock or (lambda: NOW))

    def chat(self, chat_id, *, uid=UID_A, peer=UID_B, stamp=STAMP, extra=None):
        fields = {"user1": s(uid), "user2": s(peer), "lastMessage": s("Synthetic preview"),
            "lastMessageSendBy": s("Synthetic sender"), "lastMessageSendByID": s(peer),
            "unreadMessage": {"integerValue": "3"}}
        if stamp is not None:
            fields["lastMessageSendTs"] = {"timestampValue": stamp}
        fields.update(extra or {})
        self.add("chats/" + chat_id, fields)

    def meet(self, meet_id, *, admin=UID_A, users=None, kicked=None, stamp=STAMP, extra=None):
        fields = {"admin": s(admin), "users": array(users if users is not None else [UID_A, UID_B]),
            "timeStamp": {"timestampValue": stamp}, "type": s("индивидуальная"),
            "datetime": s("14.11.2023 22:30"), "name": s("Synthetic meeting"),
            "description": s("Synthetic description")}
        if kicked is not None:
            fields["kicked"] = array(kicked)
        fields.update(extra or {})
        self.add("meets/" + meet_id, fields)

    def profile(self, uid=UID_B, *, extra=None):
        fields = {"fullName": s("Synthetic peer"), "age": {"integerValue": "32"},
            "status": s("active"), "online": {"booleanValue": True},
            "группа": s("synthetic-group"), "city": s("not-in-discovery-contract")}
        fields.update(extra or {})
        self.add("users/" + uid, fields)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.db = DiscoveryDatabase(); self.service = self.db.service()

    def test_own_chat_filter_keeps_duplicate_self_and_legacy_only_history(self):
        self.db.profile(); self.db.accounts.pop(UID_B)
        self.db.chat("own"); self.db.chat("duplicate"); self.db.chat("self", peer=UID_A)
        self.db.chat("not-owned", uid=UID_B, peer=UID_X)
        result = self.service.personal_chats(identity())
        self.assertEqual({"own", "duplicate", "self"}, {item["id"] for item in result["items"]})
        own = next(item for item in result["items"] if item["id"] == "own")
        self.assertEqual("legacy_only", own["peer"]["profileState"])
        self.assertFalse(own["peer"]["interactive"])
        self.assertEqual(UID_B, own["peer"]["uid"])
        self.assertEqual(CHAT_ORDER, result["ordering"])
        self.assertEqual(set(), {item["id"] for item in self.service.personal_chats(identity(UID_X))["items"]} - {"not-owned"})

    def test_chats_order_uses_milliseconds_binary_id_ties_and_zero_fallback(self):
        self.db.chat("A", stamp="2023-11-14T22:13:20.001999999Z")
        self.db.chat("a", stamp="2023-11-14T22:13:20.001000001Z")
        self.db.chat("latest", stamp="2023-11-14T22:13:20.002000000Z")
        self.db.chat("missing", stamp=None)
        self.db.chat("integer", stamp=None, extra={"lastMessageSendTs": {"integerValue": "1700000000999"}})
        result = self.service.personal_chats(identity())
        self.assertEqual(["latest", "a", "A", "missing", "integer"], [item["id"] for item in result["items"]])
        self.assertIsNone(result["items"][-1]["lastActivityAt"])
        self.assertIsNone(result["items"][-2]["lastActivityAt"])

    def test_chat_page_cursor_is_account_source_purpose_and_anchor_bound(self):
        for name in ["one", "two", "three"]:
            self.db.chat(name)
        first = self.service.personal_chats(identity(), limit=1)
        cursor = first["nextCursor"]
        self.assertIsInstance(cursor, str)
        second = self.service.personal_chats(identity(), limit=1, cursor=cursor)
        self.assertNotEqual(first["items"][0]["id"], second["items"][0]["id"])
        for service, caller in [(self.service, identity(UID_B)),
                (self.db.service(env={**enabled(), "CLRS_LEGACY_READ_SOURCE_SHA256": "d" * 64}), identity())]:
            with self.assertRaises(LegacyReadRejected):
                service.personal_chats(caller, cursor=cursor)
        with self.assertRaises(LegacyReadRejected):
            self.service.own_meetings(identity(), cursor=cursor)
        anchor = first["items"][0]["id"]
        self.db.chat(anchor, extra={"lastMessage": s("Changed anchor")})
        with self.assertRaises(LegacyReadRejected):
            self.service.personal_chats(identity(), cursor=cursor)

    def test_cursor_expires_and_missing_anchor_fails_closed(self):
        self.db.chat("one"); self.db.chat("two")
        first = self.service.personal_chats(identity(), limit=1)
        with self.assertRaises(LegacyReadRejected):
            self.db.service(clock=lambda: NOW + 301).personal_chats(identity(), cursor=first["nextCursor"])
        self.db.documents.pop("chats/" + first["items"][0]["id"])
        with self.assertRaises(LegacyReadRejected):
            self.service.personal_chats(identity(), cursor=first["nextCursor"])

    def test_disabled_deleted_and_malformed_peer_are_not_interactive(self):
        self.db.chat("own")
        cases = [({"deleted": {"booleanValue": True}}, (UID_B, 0, "active"), "deleted"),
            ({}, (UID_B, 1, "active"), "disabled"), ({}, (UID_B, 0, "blocked"), "disabled"),
            ({}, (UID_B, 0, "deleted"), "deleted"),
            ({"status": {"integerValue": "7"}}, (UID_B, 0, "active"), "unavailable")]
        for extra, account, expected in cases:
            with self.subTest(expected=expected):
                self.db.profile(extra=extra); self.db.accounts[UID_B] = account
                peer = self.service.personal_chats(identity())["items"][0]["peer"]
                self.assertEqual(expected, peer["profileState"])
                self.assertFalse(peer["interactive"])
                self.assertIsNone(peer["online"])
                self.assertIsNone(peer["avatar"])

    def test_peer_profile_exact_doc_identity_whitelist_group_and_thumb(self):
        self.db.chat("own")
        url = f"https://firebasestorage.googleapis.com/v0/b/{SOURCE[2]}/o/profiles%2Fsynthetic.jpg?alt=media&token=do-not-return"
        self.db.profile(extra={"uid": s(UID_X), "email": s("private@example.invalid"),
            "group": s("fallback-not-preferred"), "profilePic": s("https://outside.invalid/not-used"), "profilePicThumb": s(url)})
        peer = self.service.personal_chats(identity())["items"][0]["peer"]
        self.assertEqual(UID_B, peer["uid"])
        self.assertEqual("synthetic-group", peer["group"])
        self.assertEqual(32, peer["age"])
        self.assertTrue(peer["interactive"])
        self.assertEqual("quarantined", peer["avatar"]["status"])
        raw = json.dumps(peer)
        for value in ["https://", "private@example.invalid", "do-not-return", "profiles/synthetic.jpg", "city", "email"]:
            self.assertNotIn(value, raw)

    def test_unread_uses_current_sender_only_no_invented_sender_uid(self):
        self.db.chat("mine", extra={"lastMessageSendByID": s(UID_A)})
        self.db.chat("legacy", extra={"lastMessageSendByID": {"nullValue": None}})
        self.db.chat("malformed", extra={"unreadMessage": {"integerValue": "-1"}, "lastMessageSendByID": s("bad/uid")})
        items = {item["id"]: item for item in self.service.personal_chats(identity())["items"]}
        self.assertEqual(0, items["mine"]["unreadCount"])
        self.assertEqual(3, items["legacy"]["unreadCount"])
        self.assertIsNone(items["legacy"]["lastMessageSendByUID"])
        self.assertIsNone(items["malformed"]["unreadCount"])
        self.assertIsNone(items["malformed"]["lastMessageSendByUID"])

    def test_meetings_only_explicit_member_or_organizer_no_inferred_invitee(self):
        self.db.meet("organizer-alone", users=[UID_B])
        self.db.meet("member", admin=UID_B, users=[UID_A, UID_B])
        self.db.meet("not-member", admin=UID_B, users=[UID_B], extra={"invitedUid": s(UID_A)})
        self.db.meet("kicked", kicked=[UID_A])
        self.db.meet("legacy-individual", admin=UID_B, users=[UID_A])
        items = {item["id"]: item for item in self.service.own_meetings(identity())["items"]}
        self.assertEqual({"organizer-alone", "member", "legacy-individual"}, set(items))
        organizer = items["organizer-alone"]
        self.assertFalse(organizer["membership"]["isMember"])
        self.assertTrue(organizer["membership"]["isOrganizer"])
        self.assertFalse(organizer["canReadMessages"])
        self.assertEqual(1, organizer["participantsCount"])
        for name in ["not-member", "kicked"]:
            with self.assertRaises(LegacyReadRejected):
                self.service.meeting_details(identity(), name)

    def test_meeting_nanosecond_order_and_local_schedule_preservation(self):
        self.db.meet("A", stamp="2023-11-14T22:13:20.000000999Z")
        self.db.meet("z", stamp="2023-11-14T22:13:20.000000001Z")
        self.db.meet("equal", stamp="2023-11-14T22:13:20.000000001Z")
        result = self.service.own_meetings(identity(), limit=1)
        self.assertEqual("A", result["items"][0]["id"])
        self.assertEqual(MEETING_ORDER, result["ordering"])
        second = self.service.own_meetings(identity(), cursor=result["nextCursor"])
        self.assertEqual(["z", "equal"], [item["id"] for item in second["items"]])
        detail = self.service.meeting_details(identity(), "A")
        self.assertEqual("14.11.2023 22:30", detail["meeting"]["scheduledLocal"])
        self.assertIsNone(detail["meeting"]["scheduledTimezone"])
        self.assertEqual({"meeting", "sourceSnapshot", "membershipAuthority", "mediaReady", "readReceiptsWritten"}, set(detail))

    def test_meeting_metadata_has_no_raw_users_preferences_or_public_media(self):
        self.db.profile(UID_A)
        url = f"https://firebasestorage.googleapis.com/v0/b/{SOURCE[2]}/o/meetings%2Fsynthetic.jpg?token=do-not-return"
        self.db.meet("own", extra={"imageUrl": s(url), "secret": s("not-returned"),
            "usersWithoutNotification": array([UID_B])})
        detail = self.service.meeting_details(identity(), "own")["meeting"]
        self.assertEqual("quarantined", detail["image"]["status"])
        self.assertEqual(UID_A, detail["organizer"]["uid"])
        self.assertTrue(detail["canReadParticipants"])
        self.assertTrue(detail["canReadMessages"])
        raw = json.dumps(detail)
        for value in ["https://", "do-not-return", "meetings/synthetic.jpg", "secret", "not-returned", "usersWithoutNotification"]:
            self.assertNotIn(value, raw)

    def test_malformed_permission_parent_and_unsupported_meeting_timestamp_fail_closed(self):
        self.db.chat("own", extra={"user2": {"integerValue": "7"}})
        with self.assertRaises(LegacyReadUnavailable):
            self.service.personal_chats(identity())
        cases = [{"users": {"arrayValue": {"values": [s(UID_A), {"integerValue": "7"}]}}},
            {"kicked": {"stringValue": UID_X}}, {"admin": {"integerValue": "1"}},
            {"timeStamp": s("2023-11-14T22:13:20")}, {"users": {"nullValue": None}}]
        for extra in cases:
            self.db.meet("own", extra=extra)
            with self.assertRaises(LegacyReadUnavailable):
                self.service.meeting_details(identity(), "own")

    def test_source_hash_row_order_foreign_candidate_and_count_are_checked(self):
        self.db.chat("one"); self.db.chat("two")
        valid = list(self.db.documents.values())
        transforms = [lambda rows: [(*rows[0][:4], bytes(32), rows[0][5])],
            lambda rows: [(*rows[0][:5], Decimal(1))],
            lambda rows: list(reversed(rows)),
            lambda rows: [(*rows[0][:2], "changed-id", *rows[0][3:])]]
        for change in transforms:
            self.db.alter_result = change
            with self.assertRaises(LegacyReadUnavailable):
                self.service.personal_chats(identity())
        self.db.alter_result = None; self.db.count_override = 10_001
        with self.assertRaises(LegacyReadUnavailable):
            self.service.personal_chats(identity())
        self.assertTrue(all(connection.closed and connection.rolled_back for connection in self.db.connections))
        self.assertFalse(any(sql.startswith(("INSERT", "UPDATE", "DELETE", "COMMIT", "CREATE", "GRANT")) for sql, _ in self.db.calls))

    def test_large_response_cannot_bypass_shared_byte_limit_or_leak_partial_page(self):
        for index in range(50):
            self.db.chat(f"source-{index:03d}", extra={"lastMessage": s("я" * 4096)})
        with self.assertRaises(LegacyReadUnavailable):
            self.service.personal_chats(identity())
        self.assertTrue(self.db.connections[-1].rolled_back)
        self.assertTrue(self.db.connections[-1].closed)

    def test_case_colliding_account_result_and_tampered_profile_fail_closed(self):
        self.db.chat("own"); self.db.profile()
        self.db.accounts[UID_B] = (UID_B.lower(), 0, "active")
        with self.assertRaises(LegacyReadUnavailable):
            self.service.personal_chats(identity())
        self.db.accounts[UID_B] = (UID_B, 0, "active")
        original = self.db.documents["users/" + UID_B]
        self.db.documents["users/" + UID_B] = (*original[:4], bytes(32))
        with self.assertRaises(LegacyReadUnavailable):
            self.service.personal_chats(identity())

    def test_hidden_kicked_candidate_advances_cursor_without_exposing_metadata(self):
        self.db.meet("z-kicked", kicked=[UID_A]); self.db.meet("a-member")
        first = self.service.own_meetings(identity(), limit=1)
        self.assertEqual([], first["items"])
        self.assertIsInstance(first["nextCursor"], str)
        second = self.service.own_meetings(identity(), limit=1, cursor=first["nextCursor"])
        self.assertEqual("a-member", second["items"][0]["id"])

    def test_invalid_limit_identity_config_and_discovery_sql_driver_quoting(self):
        for limit in [0, 51, True, "2"]:
            with self.assertRaises(LegacyReadRejected):
                self.service.personal_chats(identity(), limit=limit)
        with self.assertRaises(LegacyReadRejected):
            self.service.personal_chats({"uid": UID_A})
        with self.assertRaises(LegacyReadUnavailable):
            self.db.service(env={"unused": "1"}).own_meetings(identity())
        self.assertEqual([], self.db.configs)
        import pymysql
        connection = pymysql.connections.Connection(defer_connect=True)
        connection.server_status = 0
        earlier = "1700000000000000001"; later = "1700000000000000002"
        self.assertEqual(float(earlier), float(later))
        self.assertLess(Decimal(earlier), Decimal(later))
        with connection.cursor() as cursor:
            for meeting in [False, True]:
                query = discovery_query(meeting, after=True)
                formatted = cursor.mogrify(query, (bytes(32), b"meets" if meeting else b"chats",
                    UID_A.encode(), UID_A if meeting else UID_A.encode(), later, later, b"source-id", 51))
                self.assertIn("'%Y-%m-%dT%H:%i:%s'", formatted)
                self.assertIn("LIMIT 51", formatted)
                self.assertNotIn("%%", formatted)
                self.assertEqual(2, formatted.count("CAST('1700000000000000002' AS DECIMAL(30,0))"))


if __name__ == "__main__":
    unittest.main()
