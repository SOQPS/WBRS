"""Bounded own-conversation discovery from the reviewed immutable snapshot.

Only READ methods; inherited connector/source/account/TLS gates remain intact.
No public directory, guessed invitees, implicit membership, media URL or writes.
"""
from __future__ import annotations

import hashlib
import re

from legacy_conversation_read import (LegacyConversationReadService,
    LegacyReadRejected, LegacyReadUnavailable, MAX_HISTORY, _sha, _stamp_sql)
from legacy_conversation_payload import (LegacyInvalid, MAX_DOCUMENT_BYTES,
    field, identifier, media_reference, string_field, timestamp_ns, uid_list)


CHAT_ORDER = "last_message_milliseconds_desc_utf8_id_desc"
MEETING_ORDER = "source_timestamp_desc_utf8_id_desc"
_STAMP_PATTERN = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?Z$"


def _order_sql(meeting):
    name = "timeStamp" if meeting else "lastMessageSendTs"
    path = "$.fields." + name
    stamp = f"JSON_EXTRACT(encoded_payload, '{path}.timestampValue')"
    value = f"JSON_EXTRACT(encoded_payload, '{path}')"
    order = _stamp_sql(path + ".timestampValue")
    if not meeting:
        order = f"FLOOR(({order}) / 1000000)"
    # Flutter chat sort uses milliseconds and 0 for a non-Timestamp field.
    # Meetings orderBy(timeStamp) uses the actual source Timestamp, no fallback.
    return (f"CASE WHEN JSON_TYPE({value}) = 'OBJECT' AND JSON_LENGTH({value}) = 1 "
        f"AND JSON_TYPE({stamp}) = 'STRING' AND JSON_UNQUOTE({stamp}) REGEXP '{_STAMP_PATTERN}' "
        f"THEN {order} ELSE {'NULL' if meeting else '0'} END")


def _membership_sql(meeting):
    if not meeting:
        return "(" + " OR ".join(
            f"CAST(JSON_UNQUOTE(JSON_EXTRACT(encoded_payload, '$.fields.{name}.stringValue')) AS BINARY) = %s"
            for name in ["user1", "user2"]) + ")"
    return """(CAST(JSON_UNQUOTE(JSON_EXTRACT(encoded_payload, '$.fields.admin.stringValue')) AS BINARY) = %s
      OR JSON_CONTAINS(JSON_EXTRACT(encoded_payload, '$.fields.users.arrayValue.values'),
          JSON_OBJECT('stringValue', %s)) = 1)"""


def discovery_query(meeting, *, after=False, count=False):
    member = _membership_sql(meeting)
    source = f"""FROM clrs_staging.legacy_documents
       WHERE collection_path_sha256 = %s AND CAST(collection_path AS BINARY) = %s AND {member}"""
    if count:
        return f"SELECT COUNT(*) FROM (SELECT archive_id {source} LIMIT %s) AS bounded_discovery"
    # Quoted cursor numbers must remain exact DECIMAL, not MySQL's DOUBLE
    # numeric/string comparison (which collapses adjacent Timestamp nanos).
    condition = "WHERE (order_value < CAST(%s AS DECIMAL(30,0)) OR (order_value = CAST(%s AS DECIMAL(30,0)) AND CAST(document_id AS BINARY) < %s))" if after else ""
    return f"""SELECT firebase_path, collection_path, document_id, safe_payload, payload_sha256, order_value
      FROM (SELECT firebase_path, collection_path, document_id, payload_sha256,
        CASE WHEN OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= {MAX_DOCUMENT_BYTES}
          THEN encoded_payload ELSE NULL END AS safe_payload,
        ({_order_sql(meeting)}) AS order_value {source}) AS own_discovery
      {condition} ORDER BY order_value DESC, CAST(document_id AS BINARY) DESC LIMIT %s"""


def _order(payload, meeting):
    name = "timeStamp" if meeting else "lastMessageSendTs"
    value = payload["fields"].get(name)
    if isinstance(value, dict) and set(value) == {"timestampValue"}:
        order = timestamp_ns(value["timestampValue"])
        return (order if meeting else order // 1_000_000), value["timestampValue"]
    if meeting:
        raise LegacyInvalid()
    return 0, None


def _optional(fields, name, maximum=1000):
    try:
        return string_field(fields, name, maximum)
    except LegacyInvalid:
        return None


def _integer(fields, name, maximum):
    value = fields.get(name)
    if not isinstance(value, dict) or len(value) != 1:
        return None
    raw = value.get("integerValue")
    if not isinstance(raw, str) or not re.fullmatch(r"[0-9]{1,10}", raw):
        return None
    number = int(raw)
    return number if number <= maximum else None


class LegacyConversationDiscoveryService(LegacyConversationReadService):
    """Same constructor and inherited messages/participants READ methods."""

    @staticmethod
    def _meeting_membership(parent, uid):
        fields = parent[2]["fields"]
        # Required parent authorization fields must be valid even for its admin.
        field(fields, "users", "arrayValue", required=True)
        members = uid_list(fields, "users")
        kicked = uid_list(fields, "kicked")
        organizer = identifier(string_field(fields, "admin", required=True), uid=True)
        candidate = uid == organizer or uid in members
        return organizer, members, candidate, uid in kicked

    def _profiles(self, cursor, execute, uids, *, source, binding):
        ordered = sorted(set(uids), key=lambda value: value.encode())
        if not ordered or len(ordered) > 50:
            raise LegacyReadUnavailable()
        accounts = {}; profiles = {}
        placeholders = ",".join(["%s"] * len(ordered))
        execute("SELECT uid, disabled, lifecycle FROM clrs_staging.accounts WHERE uid IN (" + placeholders + ")", tuple(ordered))
        for row in cursor.fetchall():
            if (len(row) != 3 or row[0] not in ordered or row[0] in accounts
                    or type(row[1]) is not int or row[1] not in {0, 1}
                    or row[2] not in {"active", "deleted", "blocked"}):
                raise LegacyReadUnavailable()
            accounts[row[0]] = row
        paths = {"users/" + uid: uid for uid in ordered}
        execute(f"""SELECT firebase_path, collection_path, document_id,
          CASE WHEN OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= {MAX_DOCUMENT_BYTES}
            THEN encoded_payload ELSE NULL END AS safe_payload, payload_sha256
          FROM clrs_staging.legacy_documents WHERE firebase_path_sha256 IN ({placeholders})""",
          tuple(_sha(path) for path in paths))
        for row in cursor.fetchall():
            if row[0] not in paths or row[0] in profiles:
                raise LegacyReadUnavailable()
            profiles[row[0]] = self._row(row, path=row[0], collection="users")
        result = {}
        for uid in ordered:
            account = accounts.get(uid); profile = profiles.get("users/" + uid)
            view = {"uid": uid, "name": None, "age": None, "status": None,
                "online": None, "group": None, "profileState": "missing_profile",
                "interactive": False, "avatar": None}
            if profile is not None:
                fields = profile[2]["fields"]
                view.update(name=_optional(fields, "fullName"), age=_integer(fields, "age", 150),
                    status=_optional(fields, "status", 191),
                    group=_optional(fields, "группа") if "группа" in fields else _optional(fields, "group"))
                try:
                    deleted = field(fields, "deleted", "booleanValue")
                    online = field(fields, "online", "booleanValue")
                    status = string_field(fields, "status")
                    registration = string_field(fields, "registrationStatus")
                    if (deleted is not None and type(deleted) is not bool) or (online is not None and type(online) is not bool):
                        raise LegacyInvalid()
                    if deleted is True or status == "deleted" or registration == "deleted" or (account and account[2] == "deleted"):
                        state = "deleted"
                    elif status == "blocked" or (account and (account[1] == 1 or account[2] == "blocked")):
                        state = "disabled"
                    else:
                        state = "active" if account else "legacy_only"
                    view.update(profileState=state, interactive=state == "active",
                        online=online if state == "active" else None)
                except LegacyInvalid:
                    view["profileState"] = "unavailable"
                if view["profileState"] not in {"deleted", "disabled", "unavailable"}:
                    value = _optional(fields, "profilePicThumb", 4096) or _optional(fields, "profilePic", 4096)
                    view["avatar"] = media_reference(value, bucket=source[2], codec=self._codec,
                        binding={**binding, "profile": profile[0], "profileDigest": profile[3]}, now=int(self._clock()))
            result[uid] = view
        return result

    def _metadata(self, parent, uid, *, source, binding, organizer_view):
        organizer, users, candidate, kicked = self._meeting_membership(parent, uid)
        if not candidate or kicked:
            raise LegacyReadRejected()
        fields = parent[2]["fields"]
        _, created = _order(parent[2], True)
        image = None
        for name in ["imageUrl", "meetingImageUrl"]:
            value = _optional(fields, name, 4096)
            if value:
                image = media_reference(value, bucket=source[2], codec=self._codec,
                    binding={**binding, "meeting": parent[0], "parentDigest": parent[3]}, now=int(self._clock()))
                break
        return {"id": parent[1], "name": _optional(fields, "name"),
            "description": _optional(fields, "description", 4096), "type": _optional(fields, "type", 191),
            "scheduledLocal": _optional(fields, "datetime", 100), "scheduledTimezone": None,
            "createdAt": created, "country": _optional(fields, "country"),
            "countryCode": _optional(fields, "countryCode", 20), "region": _optional(fields, "region"),
            "city": _optional(fields, "city"), "organizer": organizer_view,
            "participantsCount": len(users),
            "membership": {"isOrganizer": uid == organizer, "isMember": uid in users, "kicked": False},
            "image": image, "canReadMessages": uid in users, "canReadParticipants": True}

    @staticmethod
    def _common(pin):
        return {"sourceSnapshot": pin, "membershipAuthority": "immutable-reviewed-snapshot",
            "mediaReady": False, "readReceiptsWritten": False}

    def _discovery(self, identity, *, meeting, limit, cursor_token):
        self._limit(limit)
        collection = "meets" if meeting else "chats"
        purpose = "own_meetings" if meeting else "personal_chats"
        def action(cursor, execute, uid, source, pin):
            binding = self._binding(uid, pin, collection,
                hashlib.sha256(("immutable-discovery\0" + purpose).encode()).hexdigest(), purpose)
            after = self._cursor(cursor_token, binding)
            parameters = [_sha(collection), collection.encode(), uid.encode(), uid if meeting else uid.encode()]
            if after is not None:
                if (not isinstance(after, list) or len(after) != 3 or not isinstance(after[0], str)
                        or not re.fullmatch(r"-?[0-9]{1,30}", after[0])
                        or not isinstance(after[2], str) or not re.fullmatch(r"[a-f0-9]{64}", after[2])):
                    raise LegacyReadRejected()
                try:
                    anchor_id = identifier(after[1])
                    anchor = self._document(cursor, execute, collection + "/" + anchor_id)
                    if meeting:
                        _, _, candidate, _ = self._meeting_membership(anchor, uid)
                        if not candidate:
                            raise LegacyReadRejected()
                    else:
                        self._chat_members(anchor, uid)
                    anchor_order, _ = _order(anchor[2], meeting)
                    if anchor[3] != after[2] or str(anchor_order) != after[0]:
                        raise LegacyReadRejected()
                except LegacyInvalid:
                    raise LegacyReadRejected() from None
                parameters.extend([after[0], after[0], anchor_id.encode()])
            execute(discovery_query(meeting, count=True), tuple(parameters[:4]) + (MAX_HISTORY + 1,))
            count = cursor.fetchone()
            if not count or type(count[0]) is not int or not 0 <= count[0] <= MAX_HISTORY:
                raise LegacyReadUnavailable()
            execute(discovery_query(meeting, after=after is not None), tuple(parameters) + (limit + 1,))
            rows = cursor.fetchall()
            if len(rows) > limit + 1:
                raise LegacyReadUnavailable()
            entries = []; last = None; previous = None
            for index, row in enumerate(rows):
                parent = self._row(row, collection=collection)
                order, created = _order(parent[2], meeting)
                key = (order, parent[1].encode())
                if (len(row) != 6 or row[5] is None or str(row[5]) != str(order)
                        or (previous is not None and key >= previous)
                        or (after is not None and key >= (int(after[0]), after[1].encode()))):
                    raise LegacyReadUnavailable()
                previous = key
                if meeting:
                    organizer, _, candidate, kicked = self._meeting_membership(parent, uid)
                    if not candidate:
                        raise LegacyReadUnavailable()
                else:
                    users = self._chat_members(parent, uid)
                    organizer = users[1] if users[0] == uid else users[0]
                    kicked = False
                if index >= limit:
                    continue
                last = [str(order), parent[1], parent[3]]
                if not kicked:
                    entries.append((parent, organizer, created))
            profiles = self._profiles(cursor, execute, [entry[1] for entry in entries],
                source=source, binding=binding) if entries else {}
            items = []
            for parent, peer_uid, created in entries:
                if meeting:
                    items.append(self._metadata(parent, uid, source=source, binding=binding,
                        organizer_view=profiles[peer_uid]))
                    continue
                fields = parent[2]["fields"]
                sender = _optional(fields, "lastMessageSendByID", 191)
                if sender is not None:
                    try:
                        identifier(sender, uid=True)
                    except LegacyInvalid:
                        sender = None
                unread = _integer(fields, "unreadMessage", 2_147_483_647)
                items.append({"id": parent[1], "peer": profiles[peer_uid],
                    "lastMessage": _optional(fields, "lastMessage", 4096),
                    "lastMessageSendBy": _optional(fields, "lastMessageSendBy"),
                    "lastMessageSendByUID": sender, "lastActivityAt": created,
                    "unreadCount": 0 if sender == uid else unread,
                    "lastSharedKind": _optional(fields, "lastSharedKind", 191)})
            return {"items": items,
                "nextCursor": self._next(binding, last) if len(rows) > limit and last else None,
                "ordering": MEETING_ORDER if meeting else CHAT_ORDER, **self._common(pin)}
        return self._read(identity, action)

    def personal_chats(self, identity, *, limit=50, cursor=None):
        return self._discovery(identity, meeting=False, limit=limit, cursor_token=cursor)

    def own_meetings(self, identity, *, limit=50, cursor=None):
        return self._discovery(identity, meeting=True, limit=limit, cursor_token=cursor)

    def meeting_details(self, identity, meeting_id):
        try:
            meeting_id = identifier(meeting_id)
        except LegacyInvalid:
            raise LegacyReadRejected() from None
        def action(cursor, execute, uid, source, pin):
            parent = self._document(cursor, execute, "meets/" + meeting_id)
            organizer, _, candidate, kicked = self._meeting_membership(parent, uid)
            if not candidate or kicked:
                raise LegacyReadRejected()
            binding = self._binding(uid, pin, parent[0], parent[3], "meeting_details")
            profiles = self._profiles(cursor, execute, [organizer], source=source, binding=binding)
            return {"meeting": self._metadata(parent, uid, source=source, binding=binding,
                organizer_view=profiles[organizer]), **self._common(pin)}
        return self._read(identity, action)
