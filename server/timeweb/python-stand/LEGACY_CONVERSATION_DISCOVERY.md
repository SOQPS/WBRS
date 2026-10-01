# Own conversation discovery for the migration read stand

`LegacyConversationDiscoveryService` in `legacy_conversation_discovery.py`
inherits `LegacyConversationReadService`. Its constructor is unchanged:
`(env, cursor_key, connect=None, clock=..., monotonic=...)`. It also exposes the
existing personal messages, meeting messages and meeting participants methods.
No route, SQL mutation, new role, media fetch, paid service or deployment is
performed by this module.

The same default-off source review, immutable snapshot, current account, typed
identity, strict MySQL 8.4 staging, CA/hostname/TLS verification, three-table
SELECT role and request limits apply. See `LEGACY_CONVERSATION_READ.md` for the
whole connector contract. A typed identity is accepted only after the caller
has verified its token/session; constructing a dataclass is not authentication.

## Access and ordering evidence

Current deployed Firestore rules were read separately with Owner authorization;
their rules SHA-256 is
`af7b73ae34238175f4f504cb55d9a07b339b8778a8504cff241a4eb45af74600`.
Those rules permit signed-in reads broadly. This compatibility service adopts
the narrower current-client membership policy; it does not claim those narrower
checks were deployed in Firebase.

Client sources: `lib/presentation/screens/home/home_page.dart` queries `chats`
by `user1 == currentUID OR user2 == currentUID`, then sorts
`lastMessageSendTs.millisecondsSinceEpoch` descending, or 0 for a non-Timestamp.
`lib/app/widgets/chat_room_list.dart` derives the peer from that exact pair,
loads the peer's `users/{uid}` profile and disables actions for deleted profiles.
`lib/presentation/screens/list_of_meets/meetings.dart` orders by `timeStamp`
descending. Meeting `users`, `admin` and `kicked` are explicit source fields;
an individual type or an `invitedUid` label never creates membership.

The completed encrypted metadata shard was inspected locally with aggregate
output only: 6,102 chat roots, 201 meeting roots, 6,103 user profile roots. All
6,102 chat `lastMessageSendTs` and all 201 meeting `timeStamp` fields are typed
Firestore Timestamps in this snapshot. All meeting roots have a typed `users`
array and `admin` string; the maximum member array is 53. Two meeting roots have
`kicked` arrays. All profile ages are typed integers; `группа`, `status`,
`fullName` and `profilePic` are strings, and `online` is boolean. One profile
has `profilePicThumb`. No private UID, message, email or URL is published.

A second local decoding pass checked every source parent through the exact
service validation: 6,102 chat parents and 201 meeting parents accepted their
explicit recorded owner, without a SQL connection. Six organizers are absent
from their own recorded member array, so the metadata/messages distinction is
material. Profile mapping produced 6,027 active, four disabled and 72
legacy-only profile views; the last group has no corresponding Auth account
and is never interactive. This proof used the completed authenticated metadata
end frame and is not a live API or MySQL result. Media lookup was not exercised.

Chat ties are broken by exact UTF-8 document ID descending, keeping duplicate
pairs and self chats as distinct source roots. Meetings preserve Timestamp
nanoseconds and use the same stable tie-break. `datetime` is returned unchanged
as `scheduledLocal`; its timezone is unknown and remains `null`. An unsupported
meeting creation timestamp refuses the request rather than assigning a date.

## Python methods and planned HTTP paths

| Method | Planned route | Arguments |
| --- | --- | --- |
| `personal_chats(identity, limit=50, cursor=None)` | `GET /v1/chats` | own roots only |
| `own_meetings(identity, limit=50, cursor=None)` | `GET /v1/meetings` | explicit member or organizer, not kicked |
| `meeting_details(identity, meeting_id)` | `GET /v1/meetings/{id}` | same membership policy |

These signatures use keyword-only `limit` and `cursor`. Route parsing must
reject unknown parameters and accept an integer limit 1 through 50, plus an
opaque cursor no larger than 4,096 characters. No caller-supplied owner UID is
accepted. A valid organizer who is absent from `users` can see metadata and
participants but cannot read meeting messages. The existing message method
still requires explicit `users` membership. Kicked roots are omitted, including
those where the kicked current user is the organizer.

Lists return exactly `items`, `nextCursor`, `ordering`, `sourceSnapshot`,
`membershipAuthority`, `mediaReady`, `readReceiptsWritten`.
`nextCursor` is a string or null; items are at most 50. Ordering is
`last_message_milliseconds_desc_utf8_id_desc` for chats and
`source_timestamp_desc_utf8_id_desc` for meetings. Common flags are
`membershipAuthority: immutable-reviewed-snapshot`, `mediaReady: false`, and
`readReceiptsWritten: false`. `sourceSnapshot` is the configured verified full
source SHA-256. Meeting details use the same common flags and a single `meeting`
object, without list/cursor/order keys.

Chat items contain exactly `id`, `peer`, `lastMessage`, `lastMessageSendBy`,
`lastMessageSendByUID`, `lastActivityAt`, `unreadCount`, `lastSharedKind`.
Optional text and dates may be null; an absent legacy sender UID is not guessed
from the sender label. If the stored last sender UID is the current user,
`unreadCount` is 0, otherwise it is the retained nonnegative count or null when
malformed. Counts do not create or update read receipts.

Peer and organizer objects contain exactly `uid`, `name`, `age`, `status`,
`online`, `group`, `profileState`, `interactive`, `avatar`. The source document
path determines the UID; any stored profile UID is ignored. Name/status/group
and online may be null; age is an integer 0 through 150 or null. `группа` is
preferred, with `group` used only when the Cyrillic field is absent. The group
label does not grant a role. Profile states are `active`, `deleted`, `disabled`,
`legacy_only`, `missing_profile`, `unavailable`. Only `active` is interactive;
deleted/disabled/malformed privacy flags also suppress online and avatar.
The service never creates a missing Auth account or replaces the peer with
the current user. Profile reads and exact identity checks are batched at most
50; case/collation collisions, extra rows or changed raw hashes are refused.

Meeting objects contain exactly `id`, `name`, `description`, `type`,
`scheduledLocal`, `scheduledTimezone`, `createdAt`, `country`, `countryCode`,
`region`, `city`, `organizer`, `participantsCount`, `membership`, `image`,
`canReadMessages`, `canReadParticipants`. Organizer always uses the peer shape;
missing/invalid organizer identity denies access, and a missing profile remains
a non-interactive `missing_profile` object. `participantsCount` is the number
of distinct explicitly recorded `users`, without adding the organizer.
Membership is exactly `isOrganizer`, `isMember`, `kicked`; accessible metadata
always has `kicked: false`. It also has `canReadParticipants: true` and
`canReadMessages: isMember`. No raw users/preferences arrays are returned.

## Bounds, cursors and limits of this stage

The underlying own-root candidate count is bounded to 10,000, each SQL request
has the inherited 1-second execution limit, and the whole read uses the existing
8-second deadline, 2-second transport limits and four in-flight slots. At most
51 root rows are fetched and validated per page. Responses are bounded to
256 KiB and raw documents to 128 KiB. Unsupported/malformed membership or a
payload hash mismatch fails closed. Optional malformed display fields become
null; malformed deleted/blocked/privacy flags cannot enable actions.

Cursors are AES-GCM protected, expire in 300 seconds, and bind current UID,
source SHA, purpose and collection. Their last key also binds the exact anchor
parent digest; before continuing, that parent must still exist, match its digest,
ordering and own membership. Both SQL and readback use exact binary identities,
not collation equivalence. A kicked candidate can advance pagination without
returning its metadata, so a page may be empty and still have a next cursor.

Both numeric cursor boundaries explicitly cast the bound string to
`DECIMAL(30,0)`, including in the inherited message query. Comparing a number to
a quoted string otherwise uses DOUBLE and can collapse adjacent nanoseconds,
causing skipped/repeated pages. This behavior and the explicit-cast remedy follow
the [MySQL 8.4 type-conversion rules](https://dev.mysql.com/doc/refman/8.4/en/type-conversion.html).

After the current import transaction and the runtime-role preflight, the owner
may run this constant-only SELECT (no user rows, tables or mutations) to verify
the live server's conversion behavior. This module has not run it:

```sql
SELECT
  1700000000000000001 = '1700000000000000002' AS implicit_double_collision,
  CAST('1700000000000000001' AS DECIMAL(30,0))
    < CAST('1700000000000000002' AS DECIMAL(30,0)) AS exact_lt,
  CAST('1700000000000000001' AS DECIMAL(30,0))
    = CAST('1700000000000000002' AS DECIMAL(30,0)) AS exact_eq;
```

Expected columns are `1, 1, 0`. The offline real-driver quoting regressions check
both CAST boundaries with those same adjacent nanosecond strings; actual server
execution is a separate proof, not claimed from synthetic tests.

Avatar preference matches the current client: `profilePicThumb`, then
`profilePic`. Media uses the existing restricted opaque descriptor. Source URL
query tokens and storage paths are not returned in plaintext, and external
URLs are unavailable. Images remain quarantined; no working image link is
claimed until the reviewed media access service is integrated.

This reads an immutable reviewed import snapshot, not current join/leave,
deletion, block or favorite/archive mutations. Current token/session status and
account status still require per-request verification. Do not turn this into
the future membership authority without synchronized current membership and
privacy changes. No public meeting browse, joins, sends, invites, gifts, wall,
payment, Firebase cutover or native-login production acceptance is added here.
Orphan child history remains raw-retained and is not exposed without a valid
own parent. Controlled A/B live API checks and the actual MySQL query plan remain
required before enabling this read stand; offline tests are not deployment proof.

## Local verification

The 16 discovery and 23 inherited read tests passed on Python 3.12 (39 total).
`test_legacy_conversation_discovery.py` covers exact ownership, duplicate/self
chat retention, deleted/missing/disabled peers, source profile identity, tokens
and whitelist, ordering and timestamp precision, unread behavior, organizer
without implicit membership, kicked/invited cases, cursor account/source/purpose
and anchor guards, malformed parents, byte/count limits, raw hash collisions,
rollback-only cleanup and real PyMySQL SQL parameter quoting without opening a
connection. Run it with `test_legacy_conversation_read.py` on the Python 3.12
stand runtime using the already available PyMySQL dependency. No synthetic test
contains private source values.
