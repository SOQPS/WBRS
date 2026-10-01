import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { prepareConversationProjection, conversationProjectionSummary,
  assertPreparedConversationPlan } from '../project-conversations-core.mjs';

const source = { kind: 'source', format: 2, scope: 'metadata', completeSource: false,
  passwordHashesIncluded: false, storagePrefix: '', project: 'synthetic-conversations',
  database: '(default)', bucket: 'synthetic-conversations.appspot.com' };
const expectedSource = { project: source.project, database: source.database, bucket: source.bucket };
const s = (stringValue) => ({ stringValue });
const ts = (timestampValue) => ({ timestampValue });
const arr = (...items) => ({ arrayValue: { values: items.map(s) } });
const map = (fields) => ({ mapValue: { fields } });
const bool = (booleanValue) => ({ booleanValue });
const doc = (path, fields) => ({ kind: 'firestore-document', path, fields,
  createTime: '2026-10-01T00:00:00.000000123Z', updateTime: '2026-10-01T00:00:01.000000456Z' });
const chat = (id, a = 'synthetic-a', b = 'synthetic-b', extra = {}) => doc(`chats/${id}`, {
  user1: s(a), user2: s(b), lastMessageSendTs: ts('2026-10-01T00:00:02Z'), ...extra });
const meeting = (id, extra = {}) => doc(`meets/${id}`, { admin: s('synthetic-a'),
  type: s('групповая'), users: arr('synthetic-a', 'synthetic-b'),
  name: s('Synthetic meeting fixture'), description: s('Synthetic description fixture'),
  datetime: s('01.10.2026 12:30'), timeStamp: ts('2026-09-30T12:00:00Z'), ...extra });
const message = (parent, id, extra = {}) => doc(`chats/${parent}/chats/${id}`, {
  sendByID: s('synthetic-a'), message: s('Synthetic message fixture'), type: s('text'),
  isRead: bool(true), ts: ts('2026-10-01T00:00:05Z'), ...extra });
const meetMessage = (parent, id, extra = {}) => doc(`meets/${parent}/messages/${id}`, {
  sender: s('synthetic-b'), message: s('Synthetic meeting-message fixture'),
  time: ts('2026-10-01T00:00:06Z'), ...extra });

async function input(t, documents, { users = ['synthetic-a', 'synthetic-b', 'synthetic-c'], full = false } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-conversation-plan-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const archivePath = join(directory, 'synthetic.clrsenc');
  const key = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(archivePath, key);
  await writer.writeJson(full ? { ...source, scope: 'all', completeSource: true } : source);
  for (const uid of users) await writer.writeJson({ kind: 'auth-user', user: { uid,
    disabled: false, emailVerified: false, providerData: [] } });
  for (const record of documents) await writer.writeJson(record);
  await writer.finish({ authUsers: users.length, authListPages: 1,
    firestoreDocuments: documents.length, firestoreMissingParents: 0,
    firestoreReferences: documents.length, firestoreCollections: 1, firestoreListPages: 1,
    storageObjects: 0, storageBytes: 0, storageListPages: 0 });
  return { archivePath, key, expectedSource };
}

test('metadata plan retains every scoped record and creates only explicit account/member relationships', async (t) => {
  const main = message('one', 'm1', { replyMessage: map({ message: s('Synthetic quoted text fixture'),
    sendByID: s('synthetic-b') }) });
  const original = meetMessage('group', 'g1');
  const documents = [doc('users/synthetic-a', {}), doc('users/synthetic-b', {}),
    chat('one', undefined, undefined, { usersWOutNotifications: arr('synthetic-b') }),
    main, message('one', 'm2', { sendByID: s('synthetic-b'), ts: { integerValue: '1790812806000' } }),
    meeting('group', { usersWithoutNotification: arr('synthetic-b') }), original,
    doc('users/synthetic-a/removed_meets/group/messages/g1', original.fields),
    doc('meets/group/membership_requests/receipt', { uid: s('synthetic-b'), joined: bool(true) })];
  const plan = await prepareConversationProjection(await input(t, documents));
  const summary = conversationProjectionSummary(plan);
  assert.deepEqual(plan.counts.normalized, { chats: 1, chatMembers: 2, chatMessages: 2,
    meetings: 1, meetingMembers: 2, meetingMessages: 1, removedMeetingMessages: 1 });
  assert.equal(plan.rawRecords.length, 7);
  assert.equal(plan.counts.coverage.membershipReceipts.rawOnly, 1);
  assert.equal(plan.chatMembers.find((row) => row.uid === 'synthetic-b').notifications_enabled, 0);
  assert.ok(plan.chatMembers.every((row) => row.read_through_sequence === 0));
  assert.equal(plan.chatMessages[0].reply_to_id, null);
  assert.deepEqual(plan.chatMessages[0].legacy_raw.fields.replyMessage, main.fields.replyMessage);
  assert.equal(plan.meetings[0].starts_at, null);
  assert.equal(plan.counts.warningCounts.meeting_local_datetime_timezone_unknown, 1);
  assert.equal(plan.removedMeetingMessages[0].source_sequence, 1);
  assert.equal(plan.removedMeetingMessages[0].archived_at, '2026-10-01 00:00:00.000000');
  assert.ok(plan.meetingMembers.every((row) => row.joined_at === null && row.left_at === null));
  assert.equal(summary.databaseWrites, 0);
  assert.equal(summary.passwordMaterialRead, false);
  assert.equal(JSON.stringify(summary).includes('synthetic-a'), false);
  assert.equal(JSON.stringify(summary).includes('Synthetic message'), false);
  assert.throws(() => assertPreparedConversationPlan(plan), /planning-only/);
  assert.throws(() => conversationProjectionSummary({ ...plan }), /Authenticated/);
  assert.throws(() => plan.chats.push({}), TypeError);
});

test('missing account/profile, self-pair, orphan parents and outside senders are classified, never fabricated', async (t) => {
  const documents = [doc('users/synthetic-a', {}), chat('valid'), chat('missing', 'synthetic-a', 'not-in-auth'),
    chat('self', 'synthetic-a', 'synthetic-a'), message('valid', 'outside', { sendByID: s('synthetic-c') }),
    message('absent', 'orphan'), meeting('missing-organizer', { admin: s('not-in-auth') }),
    meeting('valid-group', { users: arr('synthetic-a', 'not-in-auth') }),
    meetMessage('valid-group', 'not-member'), meetMessage('deleted-parent', 'orphan-group')];
  const plan = await prepareConversationProjection(await input(t, documents));
  assert.equal(plan.chats.length, 1);
  assert.equal(plan.meetings.length, 1);
  assert.equal(plan.chatMessages.length, 0);
  assert.equal(plan.meetingMessages.length, 0);
  assert.equal(plan.meetingMembers.length, 1);
  assert.ok(plan.counts.warningCounts.referenced_profile_missing > 0);
  assert.equal(plan.counts.reasonCounts.chat_account_missing, 1);
  assert.equal(plan.counts.reasonCounts.chat_self_pair, 1);
  assert.equal(plan.counts.reasonCounts.message_chat_parent_unresolved, 1);
  assert.equal(plan.counts.reasonCounts.message_meeting_parent_unresolved, 1);
  assert.equal(plan.counts.participantReasons.meeting_member_account_missing, 1);
  assert.ok(plan.rawRecords.some((row) => row.firebasePath === 'chats/absent/chats/orphan'));
});

test('all duplicate pair parents and their messages remain raw-only, including reverse and Unicode pairs', async (t) => {
  const documents = [chat('a'), chat('b', 'synthetic-b', 'synthetic-a'), message('a', 'm1'),
    message('b', 'm2'), chat('case', 'Case', 'case'), chat('unicode', 'Ä', 'A\u0308')];
  const plan = await prepareConversationProjection(await input(t, documents, {
    users: ['synthetic-a', 'synthetic-b', 'Case', 'case', 'Ä', 'A\u0308'] }));
  assert.equal(plan.chats.length, 2);
  assert.equal(plan.counts.reasonCounts.duplicate_chat_pair_requires_review, 2);
  assert.equal(plan.counts.reasonCounts.message_chat_parent_unresolved, 2);
  assert.equal(plan.chatMessages.length, 0);
  for (const row of plan.chats) assert.ok(Buffer.compare(Buffer.from(row.uid_low), Buffer.from(row.uid_high)) < 0);
  assert.deepEqual(plan.chats.find((row) => row.chat_id === 'unicode').legacy_raw, documents[5] && {
    fields: documents[5].fields, createTime: documents[5].createTime, updateTime: documents[5].updateTime });
});

test('individual meetings require real distinct invited UID; rejected parents still report membership declarations', async (t) => {
  const documents = [meeting('legacy-individual', { type: s('индивидуальная') }),
    meeting('valid-individual', { type: s('индивидуальная'), invitedUid: s('synthetic-b') }),
    meeting('missing-invitee', { type: s('индивидуальная'), invitedUid: s('not-in-auth') }),
    meeting('group-conflict', { invitedUid: s('synthetic-b') }),
    meetMessage('legacy-individual', 'legacy-message')];
  const plan = await prepareConversationProjection(await input(t, documents));
  assert.equal(plan.meetings.length, 1);
  assert.equal(plan.meetings[0].kind, 'individual');
  assert.equal(plan.meetings[0].invited_uid, 'synthetic-b');
  assert.equal(plan.counts.activeParticipantEntries, 8);
  assert.equal(plan.counts.unresolvedParticipantEntries, 6);
  assert.equal(plan.counts.reasonCounts.individual_invitee_missing_or_invalid, 1);
  assert.equal(plan.counts.reasonCounts.individual_invitee_account_missing, 1);
  assert.equal(plan.counts.reasonCounts.group_has_invitee_conflict, 1);
  assert.equal(plan.meetingMessages.length, 0);
});

test('malformed typed business fields reject just their rows while intact relationships still project', async (t) => {
  const bad = { stringValue: 'synthetic-a', integerValue: '7' };
  const documents = [chat('bad', undefined, undefined, { user1: bad }), chat('good'),
    message('good', 'wrong-type', { message: { integerValue: '42' } }),
    message('good', 'bad-time', { ts: ts('2026-02-30T00:00:00Z') }),
    message('good', 'bad-sender', { sender: s('synthetic-b') }), message('good', 'okay'),
    meeting('bad-array', { users: { arrayValue: { values: [{ integerValue: '3' }] } } }),
    meeting('bad-calendar', { datetime: s('31.02.2026 12:30') }), meeting('good-group')];
  const plan = await prepareConversationProjection(await input(t, documents));
  assert.equal(plan.chats.length, 1);
  assert.equal(plan.meetings.length, 1);
  assert.equal(plan.chatMessages.length, 1);
  assert.equal(plan.counts.reasonCounts.user1_malformed, 1);
  assert.equal(plan.counts.reasonCounts.message_wrong_type, 1);
  assert.equal(plan.counts.reasonCounts.ts_invalid, 1);
  assert.equal(plan.counts.reasonCounts.message_sender_identity_conflict, 1);
  assert.equal(plan.counts.reasonCounts.users_wrong_type, 1);
  assert.equal(plan.counts.reasonCounts.datetime_invalid_local_calendar, 1);
});

test('gift/media/shared messages remain raw-only and copied quotes never invent reply foreign keys', async (t) => {
  const quote = { message: s('Synthetic quoted fixture'), sendByID: s('synthetic-b'), name: s('Synthetic fixture') };
  const documents = [chat('one'), message('one', 'image', { image: s('synthetic/path.png') }),
    message('one', 'shared', { sharedContent: map({ kind: s('post') }) }),
    message('one', 'gift', { giftNoticeName: s('Synthetic gift fixture') }),
    message('one', 'quoted', { replyMessage: map(quote), deleteFor: s('synthetic-b') })];
  const plan = await prepareConversationProjection(await input(t, documents));
  assert.equal(plan.chatMessages.length, 1);
  assert.equal(plan.counts.reasonCounts.gift_media_or_shared_message_outside_current_scope, 3);
  assert.equal(plan.chatMessages[0].reply_to_id, null);
  assert.equal(plan.chatMessages[0].deleted_at, null);
  assert.deepEqual(plan.chatMessages[0].legacy_raw.fields.replyMessage.mapValue.fields, quote);
  assert.equal(plan.rawRecords.length, documents.length);
});

test('sequences preserve nanosecond ordering, millisecond epochs and byte-exact ID ties deterministically', async (t) => {
  const documents = [chat('one'),
    message('one', 'z', { ts: ts('2026-10-01T00:00:05.000000002Z') }),
    message('one', 'Ä', { ts: ts('2026-10-01T00:00:05.000000001Z') }),
    message('one', 'A', { ts: ts('2026-10-01T00:00:05.000000001Z') }),
    message('one', 'millis', { ts: { integerValue: '1790812806000' } }),
    message('one', 'ambiguous', { ts: { integerValue: '1700000000' } })];
  const data = await input(t, documents);
  const first = await prepareConversationProjection(data);
  const second = await prepareConversationProjection(data);
  assert.deepEqual(first.chatMessages.map((row) => row.message_id), ['A', 'Ä', 'z', 'millis']);
  assert.deepEqual(first.chatMessages.map((row) => row.sequence), [1, 2, 3, 4]);
  assert.equal(first.chats[0].last_sequence, 4);
  assert.equal(first.counts.reasonCounts.ts_ambiguous_integer_epoch, 1);
  assert.equal(first.projectionSha256, second.projectionSha256);
});

test('duplicate cross-collection message IDs are classified instead of choosing a winner', async (t) => {
  const a = message('one', 'same');
  const b = { ...message('one', 'same'), path: 'chats/one/messages/same' };
  const plan = await prepareConversationProjection(await input(t, [chat('one'), a, b]));
  assert.equal(plan.chatMessages.length, 0);
  assert.equal(plan.counts.reasonCounts.duplicate_normalized_message_id_requires_review, 2);
  assert.equal(plan.chats[0].last_sequence, 0);
});

test('kicked/current conflicts, missing owners and unresolved archives never create active or fake members', async (t) => {
  const documents = [meeting('one', { users: arr('synthetic-a', 'synthetic-b', 'synthetic-b'), kicked: arr('synthetic-b') }),
    meetMessage('one', 'kicked-message'), doc('users/not-in-auth/removed_meets/one/messages/copy', {}),
    doc('users/synthetic-a/removed_meets/missing/messages/copy', {}),
    doc('users/synthetic-a/removed_meets/one/messages/copy', { message: s('Synthetic archive-only fixture') }),
    doc('removedChats/old', {})];
  const plan = await prepareConversationProjection(await input(t, documents));
  assert.deepEqual(plan.meetingMembers.map((row) => row.uid), ['synthetic-a']);
  assert.equal(plan.counts.participantReasons.meeting_member_active_and_kicked_conflict, 2);
  assert.equal(plan.meetingMessages.length, 0);
  assert.equal(plan.removedMeetingMessages.length, 1);
  assert.equal(plan.removedMeetingMessages[0].source_sequence, null);
  assert.equal(plan.counts.reasonCounts.archive_owner_account_missing, 1);
  assert.equal(plan.counts.reasonCounts.archive_meeting_parent_unresolved, 1);
  assert.equal(plan.counts.coverage.removedChatRecords.rawOnly, 1);
});

test('complete FULL archive authorizes only the prepared plan while metadata remains planning-only', async (t) => {
  const plan = await prepareConversationProjection(await input(t, [chat('one')], { full: true }));
  assert.doesNotThrow(() => assertPreparedConversationPlan(plan));
  assert.equal(plan.source.completeSource, true);
  assert.equal(conversationProjectionSummary(plan).databaseWrites, 0);
  assert.throws(() => assertPreparedConversationPlan({ ...plan }), /Authenticated/);
});

test('wrong source, incomplete/tampered/trailing archives and memory/count caps fail before any accepted plan', async (t) => {
  const data = await input(t, [chat('one')]);
  await assert.rejects(prepareConversationProjection({ ...data, expectedSource: { ...expectedSource, project: 'wrong' } }), /source mismatch/);
  await assert.rejects(prepareConversationProjection({ ...data, limits: { maxAuthUsers: 1 } }), /Auth bound/);
  await assert.rejects(prepareConversationProjection({ ...data, limits: { maxRetainedJsonBytes: 1 } }), /memory bound/);
  await assert.rejects(prepareConversationProjection({ ...data, limits: { maxFirestoreDocuments: 100_001 } }), /projection bound/);
  const ciphertext = await readFile(data.archivePath);
  for (const [suffix, bytes] of [['truncated', ciphertext.subarray(0, ciphertext.length - 1)],
    ['trailing', Buffer.concat([ciphertext, Buffer.from([1])])],
    ['tampered', Buffer.from(ciphertext)]]) {
    if (suffix === 'tampered') bytes[Math.floor(bytes.length / 2)] ^= 1;
    const path = `${data.archivePath}-${suffix}`;
    await writeFile(path, bytes, { mode: 0o600 });
    await assert.rejects(prepareConversationProjection({ ...data, archivePath: path }));
  }
});

test('duplicate creation requests classify every parent and do not fabricate members', async (t) => {
  const documents = [meeting('a', { creationRequestId: s('synthetic-request') }),
    meeting('b', { creationRequestId: s('synthetic-request') })];
  const plan = await prepareConversationProjection(await input(t, documents));
  assert.equal(plan.meetings.length, 0);
  assert.equal(plan.meetingMembers.length, 0);
  assert.equal(plan.counts.reasonCounts.duplicate_meeting_creation_request_requires_review, 2);
  assert.equal(plan.counts.activeParticipantEntries, 4);
  assert.equal(plan.counts.unresolvedParticipantEntries, 4);
});

test('legacy local ISO creation time uses real document time and path ID remains authoritative', async (t) => {
  const documents = [chat('path-id', undefined, undefined, { chatId: s('different-stored-id') }),
    meeting('one', { timeStamp: s('2026-09-30T15:30:00.123') })];
  const plan = await prepareConversationProjection(await input(t, documents));
  assert.equal(plan.chats[0].chat_id, 'path-id');
  assert.equal(plan.counts.warningCounts.legacy_chat_id_differs_from_document_path, 1);
  assert.equal(plan.meetings[0].created_at, '2026-10-01 00:00:00.000000');
  assert.equal(plan.counts.warningCounts.meeting_creation_local_iso_timezone_unknown_uses_document_create_time, 1);
});

test('noncanonical typed timestamps, numeric integer wrappers and malformed quoted maps stay raw-only', async (t) => {
  const documents = [chat('one'), message('one', 'human-time', { ts: ts('October 1 2026') }),
    message('one', 'numeric-int', { ts: { integerValue: 1790812806000 } }),
    message('one', 'bad-map', { replyMessage: { mapValue: 'not-an-object' } }), message('one', 'valid')];
  const plan = await prepareConversationProjection(await input(t, documents));
  assert.equal(plan.chatMessages.length, 1);
  assert.equal(plan.counts.reasonCounts.ts_noncanonical_timestamp, 1);
  assert.equal(plan.counts.reasonCounts.ts_invalid_integer, 1);
  assert.equal(plan.counts.reasonCounts.replyMessage_malformed, 1);
  assert.equal(plan.counts.coverage.chatMessages.source, 4);
});
