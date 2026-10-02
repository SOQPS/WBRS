# Native current meetings: isolated read projection

Status: source projection and 13 focused synthetic scenarios are verified locally.
No HTTP adapter/factory, Flutter route, deployment, permission change, schema
change, registration/join mutation, native meeting chat or cutover is included.
The current APK44 bytes are unchanged and do not contain this work.

## Authority and explicit integration prerequisite

`RuntimeMeetingsService` reads only frozen canonical `meetings`,
`meeting_members`, `profiles`, `accounts` and the existing native session store.
Empty canonical meetings return an empty list with `nextCursor: null`. No
retained import table, raw text, Firebase identity, legacy meeting fallback or
media URL is used as returned data.

The constructor requires the trusted server-side argument
`trusted_policy='reviewed-native-empty-raw-v1'`. `from_env(store, env)` returns
`None` even when the existing runtime flags and cursor key are configured. An
environment variable, HTTP request or empty `legacy_raw` cannot supply this
policy. A separate production integration must establish and review provenance
for the native writer and the intended public visibility of its empty-source
rows before supplying that argument. This module does **not** prove that `{}`
alone means native/public. Default production wiring is absent and remains off.

Within this explicitly selected narrow policy, group rows with empty source are
public metadata; individual rows are private to their exact canonical organizer
and invited UID. Nonempty meeting source is never published, including imported
rows whose source privacy/hide semantics have not been projected into reviewed
canonical visibility. Such rows need a separate reviewed projection/backfill;
this work does not erase or rewrite them. Nonempty member source is not trusted
as an active/no-kick decision: it excludes that member from the roster and denies
an actor whose current own membership row has that source.

The existing `RuntimeMutationStore.read_authenticated` owns the real native
token/current account checks before and after the transaction, TLS, MySQL8.4
schema/grant validation, serializable read-only transaction, row locks, deadline
and common maximum of 64 SQL statements. This module does not create another
authorization store. Current strict table grants do not yet include meeting
SELECT privileges; a caller with denied SQL receives `RuntimeUnavailable`.
Reviewed permissions and factory/HTTP wiring are separate prerequisites, not
changes made here. Provider-wide approved permissions, if already in use, do not
replace the provenance review.

## Service contract for a later HTTP adapter

Proposed future paths below are not routed by this patch. The adapter must use
the existing authenticated read facade, reject duplicate/unknown query options,
preserve the 64KiB envelope and distinguish current resource denial from native
actor authentication failure.

`GET /v1/runtime/meetings` corresponds to
`meetings(identity, access_token=..., scope='group', limit=30, cursor=None,
country_code=None, region=None)`.

Allowed `scope` is exactly `group` or `individual`; limit is an integer 1..30.
Optional country code is exactly an uppercase two-letter member of the existing
pinned geography catalog. Region requires that country and must be an exact
member of its region list. No trimming, translation or case rewrite is done.
The catalog pin remains
`6d696906e2ca14e09dc8516606567768b6161ceed82f84a0bdf5961ddfa93a05`.
Filters compare canonical `country_code` and `region` bytes. Partial/null stored
geography remains nullable in an unfiltered response; source geography is not a
fallback and no derived country name is added.

The exact page is:

```json
{
  "kind": "canonical-current",
  "ordering": "starts_at_asc_meeting_id_asc_null_first",
  "scope": "group",
  "items": [],
  "nextCursor": null,
  "mediaReady": false
}
```

Each item has exactly `meetingId`, `organizerUid`, `invitedUid`, `kind`, `title`,
`description`, `countryCode`, `region`, `startsAt`, `createdAt`, `updatedAt`,
`revision`, `media: null`, `mediaReady: false`. `kind` in an item is group or
individual; the outer `kind` denotes canonical read authority. Revision is a
nonnegative signed 64-bit integer. All three timestamps and all four text fields
are nullable. Timestamps use exact UTC `YYYY-MM-DDTHH:mm:ss.ffffffZ`; title is
bounded to 1000 characters/4000 UTF8 bytes, description 4096/16384, geography 191/764.
Original whitespace, newline, carriage return and tab are preserved. Other C0,
DEL and surrogates are rejected. Oversize/invalid text is not truncated or
substituted from retained source: the row is excluded or detail denied. Broken
identity, structural types, revisions, dates, duplicate or non-monotone SQL rows
fail the request closed with `RuntimeUnavailable`.

`GET /v1/runtime/meetings/{meetingId}` corresponds to
`meeting(identity, meeting_id, access_token=...)` and returns exactly
`{kind:'canonical-current', meeting:<same item>, mediaReady:false}`.

`GET /v1/runtime/meetings/{meetingId}/participants` corresponds to
`participants(identity, meeting_id, access_token=..., limit=30, cursor=None)` and
returns exactly `{kind:'canonical-current', meetingId,
ordering:'uid_binary_asc', items, nextCursor, mediaReady:false}`.
Each item is exactly `{uid,fullName,primaryGroup,joinedAt,membershipRevision,
avatar:null,mediaReady:false}`. Name and group are nullable bounded current
canonical strings (1000/4000 and 191/764); joinedAt is nullable exact UTC,
membershipRevision is nonnegative signed 64-bit. A current active actor's own
membership is included, with only its exact UID and own canonical name/group.
Missing or invalid own name/group is honestly null, including a missing own
profile row. A fake observer/public visibility decision is not fabricated.
Foreign participants require the unchanged existing public profile eligibility
evaluator. Hidden, disabled, deleted, untrusted, left or kicked foreign members
are skipped. There is no total membership or eligible count claim.

Source raw, source ID/time, email, role, balance, location/address, online state,
notification preference, meeting chat revision, image/lease URL and membership
totals are absent. Frozen schema has no reviewed public projection for those
fields. A separate media lease/read contract is needed before any image can be
shown.

## Current audience checks

Every request rereads and locks the current native actor account. Organizer and
invited UID relationships are exact current canonical values; current deleted
meeting rows are never returned. Every foreign organizer/invitee must pass the
existing current account/profile public eligibility evaluator. Hidden or
ineligible foreign organizers do not publish meetings. An actor organizing its
own meeting has the approved narrow metadata ownership exception based on its
current active account and exact organizer relation; no self public profile is
returned and no visibility relaxation applies to other people. The same current
actor relation covers access to its own individual invitation.

For a group, a nonmember and a left member can read public metadata and the
current public-eligible roster. A current kicked actor record denies list,
detail and participants. For an individual, only its exact organizer/invitee can
read metadata; the invitation metadata can remain visible after leaving.
Participants require the organizer, or the invited actor's current active
membership (neither left nor kicked). A kick denies access for either actor.
Individual roster rows outside the canonical organizer/invitee pair are not
returned. These are metadata/roster policies only. Future messages must require
current active membership and a separately reviewed meeting-chat authority;
there is no chat read or write in this module.

## Bounded pagination and SQL

Browse uses the frozen `meetings_browse_idx(kind,deleted_at,starts_at,meeting_id)`
with direct equality/range/order columns and `FORCE INDEX`, no OFFSET. Both
scopes use that index. Individual organizer OR invited audience is postfiltered
over at most 128 rows to keep meetings created by the actor; it is not an
invited-only browse. Geography and visibility are also bounded postfilters.
Roster uses `meeting_members_active_idx(meeting_id,left_at,uid)` with exact
meeting, `left_at IS NULL`, direct UID range/order and `FORCE INDEX`.
Frozen `utf8mb4_0900_bin` gives the no-pad binary code-point order corresponding
to the validated UTF8-byte keyset order. No new index or DDL was introduced.

Each scan fetches at most 32 rows and at most 128 are considered per request.
Foreign profile checks use batches of at most 64 UID per browse chunk and 32 per
roster chunk, exact current joins and bounded source/text CASE selections.
Actor memberships use at most 32 exact meeting+UID primary-key pairs per chunk.
There is no N+1 account/profile lookup. A sparse browse fixture with 128 foreign
hidden organizers uses four profile batches/four actor-member batches and stays
under the store 64-statement budget. SQL index selection/parameterization is
source-and-fixture evidence, not a live EXPLAIN or measured production latency.

StartsAt is ordered NULL first, then ascending date, then exact meeting ID.
Continuations carry the exact nullable date/ID anchor; roster uses exact UID.
The encrypted authenticated opaque cursor is domain-separated from people,
bound to actor UID, purpose, limit, exact filter digest/resource and a five-minute
window. Every continuation retains the original expiry; it never renews the
window. Wrong actor/scope/filter/limit/resource/purpose, expired/tampered or
oversize cursor is `RuntimeInvalidRequest`. Cursor is not plaintext journal
data, and the module does not log/store token or cursor secrets.

The response never exceeds 65536 bytes. It reserves 4096 bytes for a cursor while
packing, returns complete fields and anchors before an eligible item that does
not fit, so that item is considered by the next request. Skipped rows still
advance the scan anchor. At the 128-row bound a page may be empty with a nonnull
nextCursor, including a final exact-bound page that needs one manual next read
to learn it is empty. Such a page does not mean there are no matches; a client
must retain an explicit continuation control and must not automatically loop
through sparse pages. No snapshot/total coverage promise is made while current
rows/visibility change between requests. Detail/roster authorization and native
token validity are checked again on every continuation.

## Focused local evidence

Only `test_runtime_meetings` was run, using bundled Python with cryptography.
Thirteen distinct scenarios passed through the real `read_authenticated` store
and synthetic MySQL-shaped read-only fixtures, with no TCP/cloud/current users:

- default factory off even with environment policy text; honest empty canonical;
- exact nullable allowlist/source privacy/media absence/no writes;
- hidden/disabled/deleted/imported/invalid rows and own organizer exception;
- individual created/invited/private exact audience and retained invitation;
- group nonmember/left roster access and current kick/untrusted denial;
- active roster includes self with nullable bounded own fields, excludes hidden;
- sparse geo/individual/hidden-organizer scan bound and batched SQL budget;
- NULL-first/date/ID keyset plus opaque actor/filter/limit/purpose/window binding;
- sparse active roster continuation and fresh kick/organizer visibility checks;
- healthy A/B token isolation and revocation during the actual read;
- 64KiB complete text packing with no skipped unemitted row;
- malformed/duplicate/order rows and denied SQL fail closed;
- request validation and existing frozen index/parameterization proof.

The first targeted run had 12 passing cases and one incorrect test assertion
that confused the SQL eligibility column `legacy_raw` with reading a retained
import table. Only that assertion was corrected and the single affected case
rerun passed. Production permissions, provenance, HTTP mapping, real MySQL
optimizer/latency, client flow and deployment remain unverified/not enabled.

## Source binding

The two implementation/test hashes below bind this local evidence. The document
is separately hashable; no immutable APK or deployment claim is made.

| File | SHA256 |
| --- | --- |
| `server/timeweb/python-stand/runtime_meetings.py` | `880a334e036fe8f4fddc80065aee6fc6be5f81c516a63ad8a2fd26dca1e927bd` |
| `server/timeweb/python-stand/test_runtime_meetings.py` | `267c4235fba5e7ddd8b652cfe83f33f5884f891f25b3d22faf5dd4229ee8d0f4` |

Sorted JSON manifest SHA256: `21427425cfd297f4d01b4ac444e6573fb8fd07b7f155f990003fe21d3f83e215`.
