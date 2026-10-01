import { createHash } from 'node:crypto';
import { readEncryptedArchive } from './encrypted-archive.mjs';
import { payloadHash, scanImportArchive } from './import-core.mjs';
import { mysqlTimestamp } from './project-profiles-core.mjs';
import { conversationDependencies } from './project-conversations-dependencies.mjs';

const trusted = new WeakSet();
const LIMITS = Object.freeze({ maxAuthUsers: 10_000, maxFirestoreDocuments: 100_000,
  maxRetainedJsonBytes: 256 * 1024 * 1024, maxStorageObjects: 10_000,
  maxStorageBytes: 7_200_000_000, maxObjectBytes: 64_000_000 });
const COLLECTION_NAMES = new Set(['users', 'chats', 'meets', 'messages', 'removed_meets',
  'membership_requests', 'removedChats', 'TOKENS', 'posts', 'moderator_requests',
  'transaction', 'comments', 'images', 'visiters', 'likes', 'notifications', 'wall']);
const obj = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const int = (value) => Number.isSafeInteger(value) && value >= 0;
const compare = (a, b) => Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
const freeze = (value) => {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
};
class Issue extends Error { constructor(code) { super(code); this.code = code; } }
const issue = (code) => { throw new Issue(code); };

function sourceMatches(source, expected) {
  if (!obj(expected) || !['project', 'database', 'bucket'].every((key) =>
    typeof expected[key] === 'string' && expected[key] && [...expected[key]].length <= 191
      && source[key] === expected[key])) throw new Error('Conversation projection source mismatch');
}

function limits(input = {}) {
  const cap = { ...LIMITS, ...input };
  for (const [name, max] of Object.entries(LIMITS)) {
    if (!Number.isSafeInteger(cap[name]) || cap[name] < 1 || cap[name] > max) {
      throw new Error('Invalid conversation projection bound');
    }
  }
  return cap;
}

function retained(record) {
  const parts = typeof record.path === 'string' ? record.path.split('/') : [];
  if (parts.length < 2 || parts.length % 2 || parts.some((part) => !part)
      || !obj(record.fields) || typeof record.createTime !== 'string'
      || typeof record.updateTime !== 'string') throw new Error('Invalid projection document envelope');
  const encodedPayload = { fields: record.fields, createTime: record.createTime, updateTime: record.updateTime };
  return { firebasePath: record.path, documentId: parts.at(-1), encodedPayload,
    sha256: payloadHash(encodedPayload) };
}

async function scanMetadata(inputs, onAuth, onDocument, cap) {
  const sha = createHash('sha256');
  const users = new Set();
  const paths = new Set();
  let section = 'source';
  let source;
  let summary;
  for await (const frame of readEncryptedArchive(inputs.archivePath, inputs.key, {
    onCiphertext: (bytes) => sha.update(bytes),
  })) {
    if (frame.type !== 'json' || !obj(frame.record)) throw new Error('Invalid metadata projection frame');
    const record = frame.record;
    if (section === 'source') {
      if (record.kind !== 'source' || record.format !== 2 || record.scope !== 'metadata'
          || record.completeSource !== false || record.passwordHashesIncluded !== false
          || record.storagePrefix !== '') throw new Error('Invalid metadata projection source');
      source = record; section = 'auth';
    } else if (record.kind === 'auth-user' && section === 'auth') {
      if (!obj(record.user) || typeof record.user.uid !== 'string' || !record.user.uid
          || users.has(record.user.uid) || 'passwordHash' in record.user || 'passwordSalt' in record.user) {
        throw new Error('Invalid or duplicate Auth envelope');
      }
      users.add(record.user.uid);
      if (users.size > cap.maxAuthUsers) throw new Error('Conversation Auth bound reached');
      onAuth({ uid: record.user.uid, encodedPayload: record.user, sha256: payloadHash(record.user) });
    } else if (record.kind === 'firestore-document' && ['auth', 'documents'].includes(section)) {
      section = 'documents';
      const document = retained(record);
      if (paths.has(document.firebasePath)) throw new Error('Duplicate projection document');
      paths.add(document.firebasePath);
      if (paths.size > cap.maxFirestoreDocuments) throw new Error('Conversation document bound reached');
      onDocument(document);
    } else if (record.kind === 'end' && section !== 'end') {
      summary = record.summary;
      const counters = ['authUsers', 'authListPages', 'firestoreDocuments', 'firestoreMissingParents',
        'firestoreReferences', 'firestoreCollections', 'firestoreListPages', 'storageObjects',
        'storageBytes', 'storageListPages'];
      if (!obj(summary) || !counters.every((name) => int(summary[name]))
          || summary.authUsers !== users.size || summary.firestoreDocuments !== paths.size
          || summary.firestoreReferences !== paths.size + summary.firestoreMissingParents
          || summary.storageObjects !== 0 || summary.storageBytes !== 0 || summary.storageListPages !== 0) {
        throw new Error('Projection metadata completion mismatch');
      }
      section = 'end';
    } else throw new Error('Unexpected projection metadata order');
  }
  if (section !== 'end') throw new Error('Incomplete projection metadata');
  return { source, summary, archiveSha256: sha.digest('hex') };
}

function string(value, name, { required = false, chars = 191, bytes = chars * 4 } = {}) {
  if (value === undefined || value === null) { if (required) issue(`${name}_missing`); return null; }
  if (typeof value !== 'string' || Buffer.from(value, 'utf8').toString('utf8') !== value
      || [...value].length > chars || Buffer.byteLength(value, 'utf8') > bytes
      || (required && !value)) issue(`${name}_invalid`);
  return value;
}

function typed(fields, name, expected, { required = false } = {}) {
  const value = fields[name];
  if (value === undefined) { if (required) issue(`${name}_missing`); return null; }
  if (!obj(value) || Object.keys(value).length !== 1) issue(`${name}_malformed`);
  if (Object.hasOwn(value, 'nullValue')) { if (required) issue(`${name}_missing`); return null; }
  if (!Object.hasOwn(value, expected)) issue(`${name}_wrong_type`);
  return value[expected];
}
function field(fields, name, options) {
  return string(typed(fields, name, 'stringValue', options), name, options);
}
function array(fields, name) {
  const value = typed(fields, name, 'arrayValue');
  if (value === null) return [];
  if (!obj(value) || Object.keys(value).some((key) => key !== 'values')
      || (value.values !== undefined && !Array.isArray(value.values))) issue(`${name}_malformed`);
  return (value.values ?? []).map((item) => {
    if (!obj(item) || Object.keys(item).length !== 1 || !Object.hasOwn(item, 'stringValue')) issue(`${name}_wrong_type`);
    return string(item.stringValue, `${name}_uid`, { required: true });
  });
}
function date(value, name) {
  try { const result = mysqlTimestamp(value); if (!result) issue(`${name}_missing`); return result; }
  catch { issue(`${name}_invalid`); }
}
function timestamp(fields, name, fallback, warnings) {
  const value = fields[name];
  if (value === undefined || value?.nullValue !== undefined) {
    warnings.push(`${name}_uses_document_create_time`);
    return date(fallback, name);
  }
  if (!obj(value) || Object.keys(value).length !== 1) issue(`${name}_malformed`);
  if (Object.hasOwn(value, 'timestampValue')) {
    if (typeof value.timestampValue !== 'string'
        || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(value.timestampValue)) {
      issue(`${name}_noncanonical_timestamp`);
    }
    return date(value.timestampValue, name);
  }
  if (Object.hasOwn(value, 'integerValue')) {
    // This legacy branch was emitted as milliseconds since epoch. Never infer
    // seconds from magnitude or turn small/invalid integers into a current date.
    if (typeof value.integerValue !== 'string' || !/^-?\d+$/.test(value.integerValue)) issue(`${name}_invalid_integer`);
    const millis = BigInt(value.integerValue);
    if (millis < 100_000_000_000n || millis > 253_402_300_799_999n) issue(`${name}_ambiguous_integer_epoch`);
    const iso = new Date(Number(millis)).toISOString();
    warnings.push(`${name}_legacy_milliseconds`);
    return date(iso, name);
  }
  issue(`${name}_wrong_type`);
}
function orderTime(fields, name, fallback) {
  const value = fields[name];
  if (value?.timestampValue) {
    const match = /^(.*?)(?:\.(\d{1,9}))?Z$/.exec(value.timestampValue);
    return BigInt(new Date(`${match[1]}Z`).getTime()) * 1_000_000n
      + BigInt((match[2] ?? '').padEnd(9, '0'));
  }
  if (value?.integerValue !== undefined) return BigInt(value.integerValue) * 1_000_000n;
  return BigInt(new Date(fallback).getTime()) * 1_000_000n;
}
function localMeetingDate(value) {
  const match = /^(\d{1,2})\.(\d{1,2})\.(\d{4}) (\d{1,2}):(\d{2})$/.exec(value ?? '');
  if (!match) issue('datetime_invalid_local_calendar');
  const [day, month, year, hour, minute] = match.slice(1).map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day, hour, minute));
  if (year < 1000 || year > 9999 || parsed.getUTCFullYear() !== year
      || parsed.getUTCMonth() !== month - 1 || parsed.getUTCDate() !== day
      || parsed.getUTCHours() !== hour || parsed.getUTCMinutes() !== minute) issue('datetime_invalid_local_calendar');
}

function classification(record, category) {
  return { source_path: record.firebasePath, category, disposition: 'raw_only', reasons: [], warnings: [] };
}
function classified(fn, result) {
  try { return fn(); } catch (error) {
    if (!(error instanceof Issue)) throw error;
    result.reasons.push(error.code); return null;
  }
}
function profileWarning(uid, profiles, warnings) { if (!profiles.has(uid)) warnings.push('referenced_profile_missing'); }
function category(path) {
  const parts = path.split('/');
  if (parts[0] === 'chats' && parts.length === 2) return 'chats';
  if (parts[0] === 'chats' && parts.length === 4 && ['chats', 'messages'].includes(parts[2])) return 'chatMessages';
  if (parts[0] === 'meets' && parts.length === 2) return 'meetings';
  if (parts[0] === 'meets' && parts.length === 4 && parts[2] === 'messages') return 'meetingMessages';
  if (parts[0] === 'users' && parts.length === 6 && parts[2] === 'removed_meets' && parts[4] === 'messages') return 'removedMeetingMessages';
  if (parts[0] === 'meets' && parts.length === 4 && parts[2] === 'membership_requests') return 'membershipReceipts';
  if (parts[0] === 'removedChats' && parts.length === 2) return 'removedChatRecords';
  if (['chats', 'meets'].includes(parts[0])) return 'unmappedConversationDocuments';
  return null;
}

export async function prepareConversationProjection(inputs) {
  const cap = limits(inputs.limits);
  const authRecords = [];
  const sourceDocuments = [];
  const rootDocuments = [];
  const storageRecords = [];
  const profileIds = new Set();
  const rawRecords = [];
  const sourceCollections = {};
  let jsonBytes = 0;
  let documentCount = 0;
  const accountBytes = (record) => {
    jsonBytes += Buffer.byteLength(JSON.stringify(record));
    if (jsonBytes > cap.maxRetainedJsonBytes) throw new Error('Conversation JSON memory bound reached');
  };
  const onAuth = (record) => { accountBytes(record); authRecords.push(record); };
  const onDocument = (record) => {
    accountBytes(record);
    documentCount++;
    sourceDocuments.push(record);
    const parts = record.firebasePath.split('/');
    const pattern = parts.map((part, index) => index % 2 ? '*' : COLLECTION_NAMES.has(part) ? part : '<other>').join('/');
    sourceCollections[pattern] = (sourceCollections[pattern] ?? 0) + 1;
    if (parts.length === 2 && parts[0] === 'users') {
      profileIds.add(parts[1]); rootDocuments.push(record);
    }
    if (category(record.firebasePath)) {
      rawRecords.push(record);
    }
  };
  const selector = readEncryptedArchive(inputs.archivePath, inputs.key);
  let scope;
  try { scope = (await selector.next()).value?.record?.scope; } finally { await selector.return(); }
  const scanned = scope === 'all'
    ? await scanImportArchive({ ...inputs, limits: { maxAuthUsers: cap.maxAuthUsers,
      maxFirestoreDocuments: cap.maxFirestoreDocuments, maxStorageObjects: cap.maxStorageObjects,
      maxStorageBytes: cap.maxStorageBytes, maxObjectBytes: cap.maxObjectBytes }, onAuth, onDocument,
      onObject: (record) => {
        const retainedStorage = { bucket: record.source.bucket, name: record.name,
          metadata: record.metadata, size: record.size, sha256: record.sha256, targetKey: record.targetKey };
        accountBytes(retainedStorage); storageRecords.push(retainedStorage);
        // Never retain decrypted bytes in the plan. The scanner authenticates
        // one bounded object at a time; SQL verifies metadata/hash bindings.
      } })
    : await scanMetadata(inputs, onAuth, onDocument, cap);
  sourceMatches(scanned.source, inputs.expectedSource);
  const accountIds = new Set();
  let invalidAuthIdentifiers = 0;
  for (const record of authRecords) {
    try { accountIds.add(string(record.uid, 'account_uid', { required: true })); }
    catch (error) { if (!(error instanceof Issue)) throw error; invalidAuthIdentifiers++; }
  }
  const classifiedRecords = rawRecords.map((record) => ({ record, result: classification(record, category(record.firebasePath)) }));
  const chats = [];
  const chatMembers = [];
  const meetings = [];
  const meetingMembers = [];
  const chatMessages = [];
  const meetingMessages = [];
  const removedMeetingMessages = [];
  const participantClassifications = [];
  const chatCandidates = new Map();
  const meetingCandidates = new Map();
  const pairCounts = new Map();
  const requestCounts = new Map();
  for (const { record, result } of classifiedRecords) {
    const f = record.encodedPayload.fields;
    if (result.category === 'chats') {
      const candidate = classified(() => {
        const chatId = string(record.documentId, 'chat_id', { required: true });
        const storedChatId = field(f, 'chatId');
        if (storedChatId !== null && storedChatId !== chatId) result.warnings.push('legacy_chat_id_differs_from_document_path');
        const first = field(f, 'user1', { required: true });
        const second = field(f, 'user2', { required: true });
        if (first === second) issue('chat_self_pair');
        if (!accountIds.has(first) || !accountIds.has(second)) issue('chat_account_missing');
        profileWarning(first, profileIds, result.warnings); profileWarning(second, profileIds, result.warnings);
        const pair = [first, second].sort(compare);
        const pairKey = JSON.stringify(pair);
        const mute = array(f, 'usersWOutNotifications');
        if (mute.some((uid) => !pair.includes(uid))) result.warnings.push('chat_mute_uid_outside_pair');
        const row = { chat_id: chatId, uid_low: pair[0], uid_high: pair[1],
          created_at: date(record.encodedPayload.createTime, 'chat_created_at'),
          updated_at: date(record.encodedPayload.updateTime, 'chat_updated_at'),
          last_sequence: 0, revision: 0, legacy_raw: record.encodedPayload };
        return { row, pair, pairKey, mute, result };
      }, result);
      if (candidate) { chatCandidates.set(record.documentId, candidate); pairCounts.set(candidate.pairKey, (pairCounts.get(candidate.pairKey) ?? 0) + 1); }
    } else if (result.category === 'meetings') {
      const candidate = classified(() => {
        const meetingId = string(record.documentId, 'meeting_id', { required: true });
        const organizer = field(f, 'admin', { required: true });
        if (!accountIds.has(organizer)) issue('meeting_organizer_account_missing');
        profileWarning(organizer, profileIds, result.warnings);
        const kindValue = field(f, 'type', { required: true });
        const kind = kindValue === 'групповая' ? 'group' : kindValue === 'индивидуальная' ? 'individual' : null;
        if (!kind) issue('meeting_kind_unsupported');
        const invitee = field(f, 'invitedUid');
        if (kind === 'individual' && (!invitee || invitee === organizer)) issue('individual_invitee_missing_or_invalid');
        if (kind === 'individual' && !accountIds.has(invitee)) issue('individual_invitee_account_missing');
        if (kind === 'group' && invitee) issue('group_has_invitee_conflict');
        if (invitee) profileWarning(invitee, profileIds, result.warnings);
        let startsAt = null;
        if (f.datetime?.timestampValue !== undefined) startsAt = timestamp(f, 'datetime', null, result.warnings);
        else { const local = field(f, 'datetime'); if (local !== null && local !== '') { localMeetingDate(local); result.warnings.push('meeting_local_datetime_timezone_unknown'); } }
        const users = array(f, 'users');
        if (f.users === undefined || f.users?.nullValue !== undefined) result.warnings.push('explicit_active_membership_array_missing');
        const kicked = array(f, 'kicked');
        if (f.usersWithoutNotification !== undefined) {
          array(f, 'usersWithoutNotification');
          result.warnings.push('meeting_notification_preferences_retained_in_parent_raw');
        }
        const creationRequestId = field(f, 'creationRequestId');
        const row = { meeting_id: meetingId, organizer_uid: organizer,
          invited_uid: kind === 'individual' ? invitee : null, kind,
          title: field(f, 'name', { chars: 65_535, bytes: 65_535 }),
          description: field(f, 'description', { chars: 16_777_215, bytes: 16_777_215 }),
          country_code: field(f, 'countryCode'), region: field(f, 'region') ?? field(f, 'city'), starts_at: startsAt,
          created_at: f.timeStamp?.stringValue !== undefined
            ? (() => {
              const value = field(f, 'timeStamp');
              if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?$/.test(value ?? '')) {
                result.warnings.push('meeting_creation_local_iso_timezone_unknown_uses_document_create_time');
                return date(record.encodedPayload.createTime, 'meeting_created_at');
              }
              return date(value, 'meeting_created_at');
            })()
            : timestamp(f, 'timeStamp', record.encodedPayload.createTime, result.warnings),
          updated_at: date(record.encodedPayload.updateTime, 'meeting_updated_at'), media_id: null,
          creation_request_id: creationRequestId, revision: 0, deleted_at: null, legacy_raw: record.encodedPayload };
        const requestKey = creationRequestId === null ? null : JSON.stringify([organizer, creationRequestId]);
        return { row, users, kicked, result, requestKey };
      }, result);
      if (candidate) { meetingCandidates.set(record.documentId, candidate); if (candidate.requestKey) requestCounts.set(candidate.requestKey, (requestCounts.get(candidate.requestKey) ?? 0) + 1); }
    }
  }
  for (const [id, candidate] of chatCandidates) {
    if (pairCounts.get(candidate.pairKey) > 1) { candidate.result.reasons.push('duplicate_chat_pair_requires_review'); chatCandidates.delete(id); continue; }
    candidate.result.disposition = 'normalized'; chats.push(candidate.row);
    for (const uid of candidate.pair) chatMembers.push({ chat_id: id, uid, read_through_sequence: 0,
      notifications_enabled: candidate.mute.includes(uid) ? 0 : 1, archived_at: null });
    candidate.result.warnings.push('legacy_read_receipts_retained_without_sequence_inference');
  }
  const meetingMembership = new Map();
  for (const [id, candidate] of meetingCandidates) {
    if (candidate.requestKey && requestCounts.get(candidate.requestKey) > 1) {
      candidate.result.reasons.push('duplicate_meeting_creation_request_requires_review'); meetingCandidates.delete(id); continue;
    }
    candidate.result.disposition = 'normalized'; meetings.push(candidate.row);
    const active = new Set();
    candidate.users.forEach((uid, index) => {
      const participant = { source_path: `meets/${id}`, source_index: index, uid,
        disposition: 'raw_only', reasons: [], warnings: [] };
      participantClassifications.push(participant);
      if (active.has(uid)) participant.reasons.push('duplicate_active_meeting_uid');
      else if (!accountIds.has(uid)) participant.reasons.push('meeting_member_account_missing');
      else if (candidate.kicked.includes(uid)) participant.reasons.push('meeting_member_active_and_kicked_conflict');
      else {
        active.add(uid); participant.disposition = 'normalized'; profileWarning(uid, profileIds, participant.warnings);
        participant.warnings.push('membership_join_time_unknown');
        meetingMembers.push({ meeting_id: id, uid, joined_at: null, left_at: null, kicked_at: null,
          membership_revision: 0, legacy_raw: { source_path: `meets/${id}`, source_index: index,
            source_field: 'users', source_payload_hash: payloadHash(candidate.row.legacy_raw) } });
      }
    });
    if (!active.has(candidate.row.organizer_uid)) candidate.result.warnings.push('organizer_not_in_explicit_active_members');
    if (candidate.kicked.length) candidate.result.warnings.push('historical_kicked_members_retained_without_fake_timestamps');
    meetingMembership.set(id, active);
  }
  // Keep participant coverage for rejected parents as well. A failed meeting
  // mapping must not silently hide the explicit membership declarations.
  let invalidParticipantArrays = 0;
  let kickedParticipantEntries = 0;
  for (const { record, result } of classifiedRecords) {
    if (result.category !== 'meetings') continue;
    const f = record.encodedPayload.fields;
    const rawKicked = f.kicked?.arrayValue?.values;
    if (Array.isArray(rawKicked)) kickedParticipantEntries += rawKicked.length;
    if (result.disposition === 'normalized') continue;
    const rawUsers = f.users?.arrayValue?.values;
    if (rawUsers === undefined && f.users?.arrayValue && obj(f.users.arrayValue)) continue;
    if (!Array.isArray(rawUsers)) { invalidParticipantArrays++; continue; }
    rawUsers.forEach((item, index) => {
      const entry = { source_path: record.firebasePath, source_index: index, uid: null,
        disposition: 'raw_only', reasons: ['meeting_parent_unresolved'], warnings: [] };
      try { entry.uid = string(item?.stringValue, 'users_uid', { required: true }); }
      catch (error) { if (!(error instanceof Issue)) throw error; entry.reasons.push(error.code); }
      participantClassifications.push(entry);
    });
  }
  const messageCandidates = [];
  for (const { record, result } of classifiedRecords) {
    if (!['chatMessages', 'meetingMessages'].includes(result.category)) continue;
    const p = record.firebasePath.split('/');
    const f = record.encodedPayload.fields;
    const message = classified(() => {
      const messageId = string(record.documentId, 'message_id', { required: true });
      const parentId = string(p[1], 'message_parent_id', { required: true });
      const isChat = result.category === 'chatMessages';
      const parent = (isChat ? chatCandidates : meetingCandidates).get(parentId);
      if (!parent) issue(isChat ? 'message_chat_parent_unresolved' : 'message_meeting_parent_unresolved');
      const firstSender = field(f, 'sendByID');
      const secondSender = field(f, 'sender');
      if (firstSender && secondSender && firstSender !== secondSender) issue('message_sender_identity_conflict');
      const sender = string(isChat ? firstSender ?? secondSender : secondSender ?? firstSender, 'message_sender', { required: true });
      if (!accountIds.has(sender)) issue('message_sender_account_missing');
      if (isChat ? !parent.pair.includes(sender) : !meetingMembership.get(parentId).has(sender)) issue('message_sender_not_explicit_member');
      profileWarning(sender, profileIds, result.warnings);
      if (f.image !== undefined || f.giftNoticeId !== undefined || f.giftNoticeName !== undefined || f.sharedContent !== undefined) {
        issue('gift_media_or_shared_message_outside_current_scope');
      }
      const body = field(f, 'message', { required: true, chars: 16_777_215, bytes: 16_777_215 });
      const type = field(f, 'type');
      if (type && type !== 'text') issue('message_type_outside_current_scope');
      if (!type) result.warnings.push('legacy_text_without_type');
      if (f.replyMessage !== undefined) {
        const quote = typed(f, 'replyMessage', 'mapValue');
        if (!obj(quote) || (quote.fields !== undefined && !obj(quote.fields))) issue('replyMessage_malformed');
        result.warnings.push('quoted_reply_has_no_verified_message_fk');
      }
      const timeField = isChat && f.ts !== undefined ? 'ts' : 'time';
      const created = timestamp(f, timeField, record.encodedPayload.createTime, result.warnings);
      if (f.isRead !== undefined && typeof typed(f, 'isRead', 'booleanValue') !== 'boolean') issue('isRead_wrong_type');
      if (f.deleteFor !== undefined || f.deletedFor !== undefined) result.warnings.push('per_user_deletion_retained_without_global_delete_inference');
      return { isChat, parentId, messageId, sender, body, created,
        order: orderTime(f, timeField, record.encodedPayload.createTime), record, result };
    }, result);
    if (message) messageCandidates.push(message);
  }
  const messageKeys = new Map();
  for (const msg of messageCandidates) {
    const key = JSON.stringify([msg.isChat, msg.parentId, msg.messageId]);
    messageKeys.set(key, (messageKeys.get(key) ?? 0) + 1);
  }
  const sorted = messageCandidates.sort((a, b) => Number(a.isChat) - Number(b.isChat)
    || compare(a.parentId, b.parentId) || (a.order < b.order ? -1 : a.order > b.order ? 1 : 0)
    || compare(a.messageId, b.messageId));
  const sequences = new Map();
  const messageByKey = new Map();
  for (const msg of sorted) {
    const key = JSON.stringify([msg.isChat, msg.parentId, msg.messageId]);
    if (messageKeys.get(key) > 1) { msg.result.reasons.push('duplicate_normalized_message_id_requires_review'); continue; }
    const group = JSON.stringify([msg.isChat, msg.parentId]);
    const sequence = (sequences.get(group) ?? 0) + 1;
    sequences.set(group, sequence);
    const common = { message_id: msg.messageId, sequence, sender_uid: msg.sender, body: msg.body,
      media_id: null, created_at: msg.created, legacy_raw: msg.record.encodedPayload };
    const row = msg.isChat ? { chat_id: msg.parentId, ...common,
      reply_to_id: null, gift_notice_id: null, edited_at: null, deleted_at: null }
      : { meeting_id: msg.parentId, ...common };
    (msg.isChat ? chatMessages : meetingMessages).push(row);
    messageByKey.set(key, { row, record: msg.record });
    msg.result.disposition = 'normalized';
  }
  for (const row of chats) row.last_sequence = sequences.get(JSON.stringify([true, row.chat_id])) ?? 0;
  for (const { record, result } of classifiedRecords) {
    if (result.category === 'removedMeetingMessages') {
      const p = record.firebasePath.split('/');
      const row = classified(() => {
        const owner = string(p[1], 'archive_owner_uid', { required: true });
        const meetingId = string(p[3], 'archive_meeting_id', { required: true });
        const messageId = string(p[5], 'archive_message_id', { required: true });
        if (!accountIds.has(owner)) issue('archive_owner_account_missing');
        if (!meetingCandidates.has(meetingId)) issue('archive_meeting_parent_unresolved');
        profileWarning(owner, profileIds, result.warnings);
        const original = messageByKey.get(JSON.stringify([false, meetingId, messageId]));
        const sameFields = original && payloadHash(original.record.encodedPayload.fields) === payloadHash(record.encodedPayload.fields);
        if (!sameFields) result.warnings.push('archive_original_sequence_unresolved');
        return { owner_uid: owner, meeting_id: meetingId, message_id: messageId,
          source_sequence: sameFields ? original.row.sequence : null,
          archived_at: date(record.encodedPayload.createTime, 'archived_at'), legacy_raw: record.encodedPayload };
      }, result);
      if (row) { removedMeetingMessages.push(row); result.disposition = 'normalized'; }
    } else if (result.category === 'membershipReceipts') result.reasons.push('membership_receipt_retained_without_replaying_action');
    else if (result.category === 'removedChatRecords') result.reasons.push('legacy_removed_chat_record_mapping_unresolved');
    else if (result.category === 'unmappedConversationDocuments') result.reasons.push('conversation_path_not_mapped');
  }
  const classifications = classifiedRecords.map((item) => item.result);
  const sourceCounts = {};
  const coverage = {};
  const reasonCounts = {};
  const warningCounts = {};
  for (const result of classifications) {
    sourceCounts[result.category] = (sourceCounts[result.category] ?? 0) + 1;
    coverage[result.category] ??= { source: 0, normalized: 0, rawOnly: 0 };
    coverage[result.category].source++;
    coverage[result.category][result.disposition === 'normalized' ? 'normalized' : 'rawOnly']++;
    for (const reason of new Set(result.reasons)) reasonCounts[reason] = (reasonCounts[reason] ?? 0) + 1;
    for (const warning of new Set(result.warnings)) warningCounts[warning] = (warningCounts[warning] ?? 0) + 1;
  }
  const participantReasons = {};
  const participantWarnings = {};
  for (const result of participantClassifications) {
    for (const reason of new Set(result.reasons)) participantReasons[reason] = (participantReasons[reason] ?? 0) + 1;
    for (const warning of new Set(result.warnings)) participantWarnings[warning] = (participantWarnings[warning] ?? 0) + 1;
  }
  const rows = { chats, chatMembers, chatMessages, meetings, meetingMembers, meetingMessages, removedMeetingMessages };
  const counts = { sourceAuthUsers: authRecords.length, sourceFirestoreDocuments: documentCount,
    sourceStorageObjects: storageRecords.length, sourceStorageBytes: scanned.summary.storageBytes,
    invalidAuthIdentifiers, retainedConversationDocuments: rawRecords.length,
    untargetedDocuments: documentCount - rawRecords.length, sourceCounts, coverage,
    normalized: Object.fromEntries(Object.entries(rows).map(([name, values]) => [name, values.length])),
    activeParticipantEntries: participantClassifications.length,
    invalidParticipantArrays, kickedParticipantEntries,
    unresolvedParticipantEntries: participantClassifications.filter((item) => item.disposition === 'raw_only').length,
    reasonCounts, warningCounts, participantReasons, participantWarnings };
  const plan = { projectionVersion: 1, source: scanned.source, archiveSha256: scanned.archiveSha256,
    sourceCollections, counts, authRecords, sourceDocuments, rootDocuments,
    rawRecords, classifications, participantClassifications, storageRecords,
    sourceSummary: scanned.summary, ...rows };
  plan.projectionSha256 = payloadHash({ projectionVersion: 1, archiveSha256: plan.archiveSha256,
    source: inputs.expectedSource, rows, classifications, participantClassifications });
  // Keep dependency validation separate from business-row classification:
  // unsupported source accounts can still be inspected in a metadata plan,
  // but never authorize an INSERT against guessed or incomplete accounts.
  plan.dependencies = conversationDependencies(authRecords, rootDocuments);
  plan.dependencySha256 = payloadHash(plan.dependencies);
  plan.rawOnlyAcknowledgement = {
    documents: classifications.filter((item) => item.disposition === 'raw_only').length,
    participantEntries: counts.unresolvedParticipantEntries,
    reasonDigest: payloadHash({ coverage, reasonCounts, participantReasons,
      invalidParticipantArrays, invalidAuthIdentifiers }),
  };
  freeze(plan); trusted.add(plan); return plan;
}

export function assertPreparedConversationPlan(plan, { requireCompleteSource = true } = {}) {
  if (!trusted.has(plan)) throw new Error('Authenticated conversation projection plan required');
  if (requireCompleteSource && (plan.source.scope !== 'all' || plan.source.completeSource !== true)) {
    throw new Error('Metadata conversation plan is planning-only; completed FULL archive required for SQL');
  }
}

export function conversationProjectionSummary(plan) {
  assertPreparedConversationPlan(plan, { requireCompleteSource: false });
  return { projectionVersion: plan.projectionVersion, targetDatabase: 'clrs_staging',
    sourceScope: plan.source.scope, completeSource: plan.source.completeSource,
    archiveSha256: plan.archiveSha256, projectionSha256: plan.projectionSha256,
    dependencySha256: plan.dependencySha256,
    dependencyReady: plan.dependencies.ready,
    dependencyCounts: plan.dependencies.counts,
    rawOnlyAcknowledgement: plan.rawOnlyAcknowledgement,
    sourceCollections: plan.sourceCollections, counts: plan.counts,
    passwordMaterialRead: false, databaseWrites: 0, compatibilityApiReady: false };
}
