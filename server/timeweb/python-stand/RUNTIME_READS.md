# Current canonical conversation reads

`RuntimeReadService.from_env(existing_runtime_store, env)` shares the mutation
store's native proof, TLS/grants validation, eight-second budget and four-slot
worker pool. Every page uses `read_authenticated` and READ ONLY/ROLLBACK;
session revocation/version/expiry and active account are checked inside the
transaction. No second pool, mutation, legacy payload or arbitrary UID/audience
query is introduced. Existing runtime write/current-authority flags gate the
service; it remains off before current membership authority/final delta.

Factory configuration reuses `CLRS_LEGACY_READ_CURSOR_KEY_B64` through an HMAC
subkey dedicated to current read cursors. Chat cursors are encrypted and bind
the verified UID, purpose, limit and exact microsecond timestamp-or-null/chat
ID, with a 300-second expiry. Legacy media/cursors cannot be reused here.

The GET routes are `/v1/runtime/chats`,
`/v1/runtime/chats/{chatId}/messages`, `/v1/runtime/events`.
`runtime_read_http.py` mounts them through the shared `runtime_http.py`
adapter behind the existing preview and current-authority gates. No live
write/authority flag is enabled by this source change. Query names are
`limit` (1..100), discovery `cursor`,
messages `beforeSequence` (positive integer), events `afterEventId` (0..2^63-1).
The caller never supplies a target UID. Wrong/inaccessible chat raises
`RuntimeReadRejected` for generic HTTP404; invalid cursor/limits are HTTP400.

Exact envelopes:

- Chats: `{kind:'canonical-current',ordering:'updated_at_desc_chat_id_asc_null_last',items,nextCursor}`.
  Item: `{chatId,counterpartUid,name,avatar:null,updatedAt,lastSequence,revision,readThrough,archived,notifications}`.
- Messages: `{kind:'canonical-current',chatId,chatRevision,ordering:'sequence_desc',items,nextBeforeSequence}`.
  Item: `{chatId,messageId,sequence,senderUid,text,quote,createdAt}`.
  Quote: null or `{messageId,sequence,senderUid,text}`.
- Events: `{kind:'canonical-current',ordering:'event_id_asc',items,nextAfterEventId}`.
  Item: `{eventId,kind,chatId,messageId,sequence,senderUid,readerUid,readThroughSequence,chatRevision,createdAt}`.

All continuation fields are nullable. Historical message text/timestamps and
profile names may be null; genuine empty historical text remains empty.
Timestamps use six fractional UTC digits. Text is at most 4096 code points/
16384 UTF-8 bytes, name 1000/4000; ASCII controls except CR/LF/TAB, DEL and
surrogates fail closed. IDs have at most 191 code points/764 bytes, no controls.
Sequence/revision values use signed 63-bit bounds. The minimal message DTO
matches send receipt content, without inventing per-message event IDs or the
original send revision unavailable from its canonical row.

Both exact membership rows and both active accounts authorize each pair;
extra/missing members fail closed. `archived_at` affects only the returned UI
state. Discovery filters inaccessible pairs before LIMIT and sorts recent to
old, equal timestamps by byte-exact ID ascending, null timestamps last.
Messages exclude deleted rows, and quotes are reread from the same accessible
chat with deletion checked; retained quote snapshots cannot bypass deletion.

Only `chat.message.created.v1` and `chat.read.updated.v1` own-audience events
are queried. Their server-defined payloads must have exact expected fields and
pair identities; arbitrary JSON is never returned. Created events have
messageId/sequence/senderUid and null reader/readThrough; read events have the
opposite nullability. Event createdAt is the canonical event row timestamp.

Queries fetch at most limit+1 rows. Adaptive packing keeps the public envelope
within **65536 UTF-8 bytes**, preserving complete texts/quotes. Continuation
always follows the last emitted row; no private filtered row becomes a cursor
anchor. Historical attachment/gift metadata hydration, avatar references,
event consumption/UI wiring and live current-authority acceptance remain
separate gates. This preparation does not claim complete attachment history.

Eight focused no-TCP tests cover post-write data, current access/blocking,
deleted messages/quotes, exact microsecond/null cursor ordering, cursor
account/limit binding, byte-budget continuation, safe event descriptors,
nullable historical fields and read-only transaction behavior.

A fresh isolated MySQL **8.4.4** instance passed six additional targeted SQL
checks: JOIN/FOR SHARE aliases, adjacent microsecond/equal/null discovery
keysets, whole-message byte continuation, own-event JSON joins/filtering,
deleted quoted parents and blocked filtering before LIMIT. It used generated
fixtures over a Unix socket, networking/mysqlx disabled, then shut down.
Only grant/TLS preflight rows were injected: no deployed TLS/role acceptance
or production/staging user-data operation is claimed.
