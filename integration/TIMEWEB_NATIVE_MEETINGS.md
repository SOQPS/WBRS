# Native meetings on Timeweb

The integration branch includes native meeting creation, self-only joining,
list/detail/participants reads and their Flutter routes. The server is deployed
to existing Timeweb stand 5179, GitLab commit
`fd8bf47922fe7727839ac8aa3048d50257d52a88`.
The operator preview guard remains enabled; the main app deployment is stopped.
The deployed join route returns404 without the operator proof and401 with proof
but without a native bearer. These refusals are deployment/guard evidence,
not a successful real-user creation, join, old-password login or full cutover.
Native release flags remain false. Permissions, schema and imported rows were
not changed by these patches.

## Current authority

The app factory explicitly injects `reviewed-native-marker-v1` into the existing
RuntimeMeetingsService. Default adapters without trusted injection stay closed.
The shared RuntimeMutationStore owns native bearer/current-account checks,
TLS/grant validation, bounded transactions, row locks, deadlines and receipts.
Firebase identity or retained source is not a serving fallback.

Readers accept only the exact server-built meeting marker
`{origin:'clrs-native-meeting-v1',localDatetime:'03.10.2026 19:15'}` and member
marker `{origin:'clrs-native-meeting-member-v1'}` with a real server joined time.
Extra keys, malformed markers, old empty raw and typed imported Firestore roots
are excluded. The existing155 imported meetings are retained and excluded;
their unknown historical joined times are not overwritten.

Current canonical title, description and geography must validate. Names remain
byte-for-byte bounded1000 characters/4000UTF8 bytes, descriptions4096/16384;
empty descriptions are allowed. Geography uses the unchanged pinned catalog
`6d696906e2ca14e09dc8516606567768b6161ceed82f84a0bdf5961ddfa93a05`.
Local meeting time is exact `dd.MM.yyyy HH:mm` with a real calendar date.
`starts_at` stays NULL; no timezone or calendar ordering is guessed.

Current deleted/disabled accounts, hidden foreign organizers, ineligible people,
untrusted rows and kicked actors are denied. Group metadata is public to eligible
native actors. Individual metadata is restricted to its exact organizer/invitee;
individual participants require the organizer or an active invited membership.
Foreign roster rows must pass current public profile eligibility; an active actor
can see its own exact membership. No count, online state, email, balance, raw
source or unreviewed media URL is returned.

## HTTP contract

`GET /v1/runtime/meetings` accepts scope `group` or `individual`, limit1..30,
optional exact countryCode and matching region, and an opaque cursor.
`GET /v1/runtime/meetings/{meetingId}` returns current detail.
`GET /v1/runtime/meetings/{meetingId}/participants` accepts limit1..30/cursor.

Pages have kind `canonical-current`, exact typed items, nextCursor and
mediaReady:false. Meeting items expose meetingId, organizerUid, invitedUid, kind,
title, description, countryCode, region, startsAt, localDatetime, createdAt,
updatedAt, revision, media:null and mediaReady:false. Participant items expose
uid, fullName, primaryGroup, joinedAt, membershipRevision, avatar:null and
mediaReady:false. The native policy requires localDatetime/nonblank title and a
valid geography pair. Nullable current roster names stay honestly null.

Reads use the existing frozen browse/member indexes, no OFFSET or source scan.
At most128 source rows are considered per request, foreign profiles are batched,
and the shared64-statement/64KiB budgets remain. Meeting order is NULL-first
starts_at/meetingId; roster order is binary UID. The encrypted cursor binds actor,
resource, filters, limit, purpose and the original five-minute expiry. Empty sparse
pages retain an explicit next-page control; clients do not automatically loop.
This is bounded source/fixture evidence, not a measured production latency claim.

`POST /v1/runtime/meetings`, operation `meeting.create.v1`, accepts exactly
operationId, name, description, countryCode, region, datetime, type; an individual
also requires invitedUid. Type is exactly `групповая` or `индивидуальная`.
Clients cannot supply organizer, members, raw/origin, media, server timestamps or
legacy copies of country/city/person names. The current actor profile must be
ready for search. Individual invitations require a current eligible other user.

Creation atomically inserts the meeting, creator-only membership and original
receipt. The actor plus original operation UUID determine meetingId. Success201
has result `{meetingId,created:true,meetingRevision:0,localDatetime}` and
entityRevision0. Matching committed errors are404profile_not_found,
409profile_not_ready and404person_unavailable. Receipt replay validates the
original UUID-derived meetingId and row creation_request_id, current native
marker and active creator membership; another same-owner meeting cannot confirm
an unresolved original operation.

`POST /v1/runtime/meetings/join`, operation `meeting.join.v1`, accepts exactly
operationId and meetingId. It joins only the current actor, with no client-supplied
member list. New group membership requires current eligible meeting authority;
new individual membership requires the exact current invited UID. Existing active
trusted membership returns an honest no-op and preserves joined_at. Left, kicked
and untrusted memberships are not overwritten or automatically rejoined.

Success200 has result `{meetingId,joined:true,alreadyMember,membershipRevision}`;
entityRevision equals membershipRevision. Matching committed errors are
404meeting_not_found/profile_not_found and409meeting_unavailable/profile_not_ready.
Join INSERT and receipt are atomic. Receipt lookup binds the original meetingId
and current active self membership; changed access returns a short404 without
logging out a healthy actor. Revoked native authority still returns401.

Both writers require the already-supported provider-database permission model
and existing exact indexes; denied configuration fails closed. No grants, DDL,
source rewriting, unrelated profile updates or imported membership history are
introduced. Unknown COMMIT is reconciled by original receipt lookup only.

## Flutter behavior

TimewebAppRuntime uses existing current-profile/read/write gates. The native
MeetingForm branch is chosen before the legacy State can construct Firebase
services. Native edit/delete remains unavailable. Invitees come from current
native people DTOs; the request contains only the typed six fields and optional
exact UID. List, detail and participants use current native readers and bounded
manual pagination; there is no legacy query/media fallback.

Creation and joining persist the immutable original UUID/hash/fields before POST
in application-private journals bound to endpoint/UID and, for join, meetingId.
Double taps share one pending operation. Restart and uncertain replies offer only
original lookup; not_found does not authorize a resend. Every short/nonreceipt
response preserves UNKNOWN. Final confirmation/rejection requires the exact
matching committed envelope and allowed result. Durable ACK completes before
navigation or participant refresh. A newly refused lookup cannot reuse an earlier
cached confirmation.

DTO getters and cursors retain UID/session-epoch guards. Account changes clear
cached meetings, participants, form fields, picked names, pending RAM receipts
and owned dialogs; late A responses cannot render in B. The original disk intent
is retained for its original account. Network cancellation/drain and the existing
common four-request budget are reused.

The native list follows Dmitry's supplied layout: family background and visible
hero, logo/slogan with heart, title/Create in one row,75% transparent Create,
horizontal geography filters, metadata/roster panels on the left two-thirds.
The same approved meeting guide is reused with legacy navigation disabled;
its dialogs stay inside the owned native navigator. The participants link is
`Участники встречи`. No unsupported chat button or fabricated meeting image is
shown. Meeting messages, leave/kick actions, push and imported-meeting serving
remain separate cutover work.

## Focused evidence and limits

Server evidence:29 focused creator/reader/HTTP cases, then4 targeted join cases
including replay/no-op, individual eligibility, left/kick/import refusal,
revocation, atomic rollback and unknown COMMIT. Only affected fixture cases were
repaired/rerun. There was no broad server suite or live fake-account write.

Client evidence:9 transport cases, one creation flow case,2 creation/read widget
cases,4 join client/flow cases and one join widget case. Scoped analyzers report
No issues. These cover exact receipt identity/status/fields, sparse continuation,
original-only lookup, A-to-B cleanup, cancellation/drain, no Firebase init in the
native form and ACK before detail/roster reads. A360px local native-list render
was compared with the supplied concept; this is not a screenshot from a user's
phone. Root changed only the participants link text after frozen UI verification.

Frozen patches were independently reviewed, applied in order and matched their
source manifests. Credentials remain outside source/APK. Full source hashes,
local logs, guarded deployment proof and remaining work are retained in the
private migration checkpoint. This implementation does not prove all historical
meetings/photos recovered, SMTP delivery, old-password sign-in, device acceptance
or completed migration. Public activation requires those remaining cutover steps.
