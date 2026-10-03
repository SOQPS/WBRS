# Native current meeting creation and reads

Status: reviewed creator/marker, receipt repair and app construction wiring are
applied to the integration branch. One focused invocation passed 29/29 synthetic
scenarios (13 reader +11 HTTP +5 creator), including the reviewed app factory.
The server implementation is ready for the existing guarded Timeweb preview;
this source review does not prove a real user creation or production cutover.
Flutter routes, flags, permissions, schema, APK44 and imported rows are unchanged.

## Authority and explicit integration prerequisite

`RuntimeMeetingsService` reads only frozen canonical `meetings`,
`meeting_members`, `profiles`, `accounts` and the existing native session store.
Empty canonical meetings return an empty list with `nextCursor: null`. No
retained import table, raw text, Firebase identity, legacy meeting fallback or
media URL is used as returned data.

The constructor now requires the reviewed server-side policy
`trusted_policy='reviewed-native-marker-v1'`. `from_env(store, env)` still returns
`None` without explicit trusted injection. No environment flag or request can
supply that authority. Defaults in RuntimeReadHttp/RuntimeMeetingsHttp remain closed. A separate
reviewed app-local construction patch explicitly injects this policy using the
existing shared store; the isolated factory test is not deployment evidence.

Only the exact flat server-built meeting marker is accepted:
`{origin:'clrs-native-meeting-v1',localDatetime:'03.10.2026 19:15'}`.
`localDatetime` must have the current MeetingForm `dd.MM.yyyy HH:mm` shape and a
real calendar date. The SQL `starts_at` stays NULL. The only accepted member
marker is `{origin:'clrs-native-meeting-member-v1'}`, with a non-null server-time
`joined_at`. Extra keys, wrong types/values, old empty raw and original imported
Firestore typed roots are excluded. The existing 155 imported meetings remain
excluded; their original source and unknown historical joined times are not
changed. Markers are not cryptographic proof: trusted injection still requires
review of the sole native writer and retained-source import paths.

Group marker rows are public metadata; individual marker rows remain private
to their exact organizer/invitee. The existing current visibility, left/kicked,
actor pre/post checks, bounded sparse pagination and participant policy remain.
Native title/description/geography must validate; source fallback is not used.

The existing `RuntimeMutationStore.read_authenticated` owns the real native
token/current account checks before and after the transaction, TLS, MySQL8.4
schema/grant validation, serializable read-only transaction, row locks, deadline
and common maximum of 64 SQL statements. This module does not create another
authorization store. Current strict table grants do not yet include meeting
SELECT privileges; a caller with denied SQL receives `RuntimeUnavailable`.
Reviewed permissions and factory/HTTP wiring are separate prerequisites, not
changes made here. Provider-wide approved permissions, if already in use, do not
replace the provenance review.

## Read service contract

The existing default-closed HTTP adapter preserves native authority, strict
query/body bounds and the 64KiB envelope. This isolated patch adjusts its exact
DTO validator and the mutation dispatcher without activating a reader factory.

`GET /v1/runtime/meetings` corresponds to
`meetings(identity, access_token=..., scope='group', limit=30, cursor=None,
country_code=None, region=None)`.

Allowed `scope` is exactly `group` or `individual`; limit is an integer 1..30.
Optional country code is exactly an uppercase two-letter member of the existing
pinned geography catalog. Region requires that country and must be an exact
member of its region list. No trimming, translation or case rewrite is done.
The catalog pin remains
`6d696906e2ca14e09dc8516606567768b6161ceed82f84a0bdf5961ddfa93a05`.
Filters compare canonical `country_code` and `region` bytes. Native marker rows must contain the exact valid geography pair. Source
geography is not a fallback and no derived country name is added.

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
`revision`, nullable `localDatetime`, `media: null`, `mediaReady: false`. `kind` in an item is group or
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

## Isolated native creator review patch

`POST /v1/runtime/meetings`, operation `meeting.create.v1`, accepts exactly
`{operationId,name,description,countryCode,region,datetime,type}` and additionally
`invitedUid` only when `type='индивидуальная'`; group type is `'групповая'`.
Name is nonblank bounded 1000/4000, description 4096/16384 (empty allowed), both
retain bytes; date is the exact current dot-date local text. Geography reuses
`resolve_geography` and the unchanged catalog pin above. Clients cannot supply
raw/origin, organizer, member lists, server timestamps, country/city/name copies,
media or notification fields. Individual self-invitation is rejected.

The actor's current canonical profile is SHARE-locked and decoded by the existing
own-profile decoder; its onboarding must be `search` (complete flag or recognized
current primary group). An individual invitee reuses the existing current pair
visibility/locked account-profile guard. Missing own profile returns a committed
404 `profile_not_found`, nonready own profile 409 `profile_not_ready`, and an
unavailable invitee 404 `person_unavailable`.

The fixed server action uses the existing RuntimeMutationStore session/account
locks and transaction. It validates the existing exact nonprefix binary primary,
creator-request and member indexes; no DDL is performed. The actor and original
operation ID determine the meeting ID. A unique organizer/request key and the
existing receipt store retain that original intent. Meeting INSERT and its only
initial member (the creator) are atomic; no membership is fabricated for the
invitee. Raw markers and created/updated/joined server times are server-built.
Readback verifies the row and member before the receipt is committed.

Success HTTP201 has existing receipt envelope/result
`{meetingId,created:true,meetingRevision:0,localDatetime}`, entityRevision0.
Original POST/receipt lookup repeats that outcome with the same owner/hash/ID;
unknown COMMIT requires fresh lookup and never causes an automatic POST/new ID.
Error-only declared receipts remain failures. Success lookup rechecks the current
profile/visibility, exact marked row and active creator membership. Target denial
is thin404 `meeting_unavailable` without logging out a healthy actor; a revoked
actor still receives401. A different actor cannot read A's receipt/private detail.

Creation is refused with503 under the existing strict-tables permission model;
only the already-supported provider database permission model can insert these
tables. Fresh grant verification is unchanged, and no permissions are expanded.
The adapter defaults stay closed. The reviewed app-local factory injection
selects the native creator marker policy. UI/Firestore POST paths and
provider deployment are not switched here.
Local dates are displayed as wall-clock text, not UTC or guaranteed calendar
ordering: the existing NULL-first `starts_at/id` keyset order remains deterministic.

One invocation of `test_runtime_meeting_create` passed four focused scenarios:
actual HTTP create/replay/lookup/detail/roster plus imported/empty marker denial;
unknown COMMIT both committed/not-found after restart without second INSERT and
owner B isolation; invalid fields/geography/profile, denied grants and atomic
member rollback; individual visibility, kick, target404 and revoked actor401.
No SQL server, network, keys, cloud/provider API, deployment, flags, broad suite,
APK or schema changes were used. Original imported joined history remains unknown.

## Receipt repair and fixture compatibility layer

A native success replay now opts into the original-operation-ID guard. The store
passes the lookup/POST receipt key to this guard without changing old request or
response guard signatures. Response meetingId must equal the ID derived from the
exact current actor plus that original operation ID; current row creation_request_id
must equal the original operation ID as well. A different same-owner/same-payload meeting cannot
confirm a pending original operation. Error-only declared receipts remain intact.
The added case substitutes a valid other-operation success into an unknown-commit
receipt, verifies rejection, then checks the genuine original success and the old
personal response guard. Existing reader/HTTP fixtures use exact native markers
and localDatetime; UTC-bearing rows do not match this narrow native marker policy.

## Separate app wiring layer and focused verification

`app.py` uses an app-local default runtime factory that constructs the existing
RuntimeMutationHttp with meetings_factory calling
RuntimeMeetingsService.from_env(store,env,trusted_policy=TRUSTED_POLICY).
Custom injected runtime factories keep the original factory(env) signature.
This reuses the existing native bearer/session authority, common SQL store,
cursor key, runtime flags and preview guard. There is no new pool, resource,
permission or flag; denied/missing existing permissions/configuration still fail
closed. It publishes only the exact new native markers, never imported meetings.
Adapter/class defaults without explicit policy remain closed.

The focused factory case executes this exact app construction function (without
importing unrelated auth/media configuration), supplies the existing synthetic
store through the constructor seam, and verifies native detail200/localDatetime
through the real reader and HTTP adapter, plus unwired default503. The three
agreed modules passed in one invocation: 29 tests, 0.207s. No further suites were
run. The immutable review layers were applied in order and matched their frozen
source hashes. Real user acceptance and the native Flutter creation/invitee path
remain separate work; this is not an APK or cutover claim.
