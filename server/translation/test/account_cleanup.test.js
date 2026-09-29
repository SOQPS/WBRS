import assert from 'node:assert/strict';
import test from 'node:test';
import { createAccountCleanup, createAuthDeleteCleanupHandler } from '../src/account_cleanup.js';

const CLOCK = Date.UTC(2026, 8, 28, 12);
const REQUESTED = CLOCK - 10000;
const DELETED = CLOCK - 5000;
const DELETED_FIELD = Symbol('delete');
const stamp = ms => ({ seconds: Math.floor(ms / 1000), nanoseconds: (ms % 1000) * 1e6,
  toMillis() { return this.seconds * 1000 + this.nanoseconds / 1e6; } });
function clone(value) {
  if (value?.toMillis) return stamp(value.toMillis());
  if (Array.isArray(value)) return value.map(clone);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, clone(entry)]));
  return value;
}

class Database {
  constructor() { this.docs = new Map(); this.queue = Promise.resolve(); this.version = 0; this.beforeCommit = null; this.deletes = []; }
  put(path, data, updated = REQUESTED - 1000, created = REQUESTED - 2000) {
    this.docs.set(path, { data: clone(data), updated, created: this.docs.get(path)?.created ?? created, version: ++this.version });
  }
  snapshot(path) {
    const entry = this.docs.get(path);
    return { id: path.split('/').at(-1), ref: this.doc(path), exists: !!entry,
      data: () => entry ? clone(entry.data) : undefined,
      createTime: entry ? stamp(entry.created) : undefined,
      updateTime: entry ? stamp(entry.updated) : undefined };
  }
  doc(path) { return { path, id: path.split('/').at(-1), get: async () => this.snapshot(path) }; }
  collection(path) { return new Query(this, path); }
  async runTransaction(run) {
    const previous = this.queue;
    let release;
    this.queue = new Promise(resolve => { release = resolve; });
    await previous;
    try {
      for (let attempt = 0; attempt < 4; attempt++) {
        const reads = new Map(), writes = [];
        const result = await run({
          get: async ref => { reads.set(ref.path, this.docs.get(ref.path)?.version); return this.snapshot(ref.path); },
          set: (ref, data) => writes.push({ kind: 'set', ref, data }),
          update: (ref, data) => writes.push({ kind: 'update', ref, data }),
          delete: ref => writes.push({ kind: 'delete', ref }),
        });
        if (this.beforeCommit) await this.beforeCommit({ reads, writes });
        if ([...reads].some(([path, version]) => this.docs.get(path)?.version !== version)) continue;
        for (const { kind, ref, data } of writes) {
          if (kind === 'delete') { this.docs.delete(ref.path); this.deletes.push(ref.path); continue; }
          const next = kind === 'set' ? clone(data) : { ...this.docs.get(ref.path)?.data };
          for (const [field, value] of Object.entries(data)) {
            if (value === DELETED_FIELD) delete next[field]; else next[field] = clone(value);
          }
          this.put(ref.path, next, CLOCK);
        }
        return result;
      }
      throw new Error('transaction conflict');
    } finally { release(); }
  }
}
class Query {
  constructor(db, path, count = Infinity, after = '') { Object.assign(this, { db, path, count, after }); }
  orderBy() { return this; }
  limit(count) { return new Query(this.db, this.path, count, this.after); }
  startAfter(cursor) { return new Query(this.db, this.path, this.count, cursor.id); }
  async get() {
    const depth = this.path.split('/').length + 1;
    const docs = [...this.db.docs.keys()].filter(path => path.startsWith(this.path + '/') && path.split('/').length === depth)
      .map(path => this.db.snapshot(path)).sort((a, b) => a.id.localeCompare(b.id))
      .filter(entry => entry.id > this.after).slice(0, this.count);
    return { docs, size: docs.length };
  }
}
class Bucket {
  constructor() { this.name = 'offline-bucket'; this.objects = new Map(); this.removed = []; this.beforeDelete = null; this.beforeMetadata = null; this.listExtra = null; }
  put(name, generation = '1', ms = REQUESTED - 2000) {
    this.objects.set(name, { generation, metageneration: '1', timeCreated: new Date(ms).toISOString(), updated: new Date(ms).toISOString() });
  }
  async getFiles({ prefix, maxResults, pageToken = '' }) {
    const names = [...this.objects.keys()].filter(name => name.startsWith(prefix) && name > pageToken).sort().slice(0, maxResults);
    const files = names.map(name => this.file(name));
    if (this.listExtra) files.push(this.file(this.listExtra));
    return [files, names.length === maxResults ? { pageToken: names.at(-1) } : null];
  }
  file(name, options = {}) {
    return { name,
      getMetadata: async () => {
        if (this.beforeMetadata) await this.beforeMetadata(name);
        if (!this.objects.has(name)) throw { code: 404 };
        return [{ ...this.objects.get(name) }];
      },
      delete: async ({ ignoreNotFound }) => {
        assert.equal(ignoreNotFound, true);
        if (this.beforeDelete) await this.beforeDelete(name);
        const stored = this.objects.get(name);
        if (!stored) return;
        assert.ok(options.preconditionOpts, 'Storage delete needs a generation condition');
        if (stored.generation !== options.preconditionOpts.ifGenerationMatch ||
            stored.metageneration !== options.preconditionOpts.ifMetagenerationMatch) throw { code: 412 };
        this.objects.delete(name); this.removed.push(name);
      },
    };
  }
}
const photo = name => `https://firebasestorage.googleapis.com/v0/b/offline-bucket/o/${encodeURIComponent(name)}?alt=media&token=private-download-token`;
function setup() {
  const db = new Database(), bucket = new Bucket();
  const auth = { existing: new Set(), calls: 0, beforeGet: null, async getUser(uid) {
    this.calls++; if (this.beforeGet) await this.beforeGet(uid, this.calls);
    if (this.existing.has(uid)) return { uid };
    throw { code: 'auth/user-not-found' };
  } };
  const input = { uid: 'a', eventId: 'auth-deletion-one', deletedAt: new Date(DELETED).toISOString(),
    createdAt: new Date(REQUESTED - 86400000).toUTCString() };
  const options = { db, auth, bucket, enabled: () => true, now: () => CLOCK,
    timestamp: () => stamp(CLOCK), deleteField: () => DELETED_FIELD };
  const backend = createAccountCleanup(options);
  db.put('users/a', { uid: 'a', status: 'deleted', deletionRequestedAt: stamp(REQUESTED),
    fullName: 'Private name', email: 'private@example.test', about: 'Private biography',
    profilePic: photo('users/a/photos/portrait.jpg'), balance: 27,
    gifts: ['preserved'], isUnVisible: true, unknownField: 'must remain' }, REQUESTED);
  db.put('users/a/images/portrait', { url: photo('users/a/photos/portrait.jpg') });
  db.put('users/a/notifications/one', { type: 'meeting', title: 'Private notice', read: false, createdAt: stamp(REQUESTED - 2000) });
  db.put('TOKENS/a', { token: 'private-device-token' });
  db.put('private_users/a', { email: 'private@example.test' });
  db.put('public_profiles/a', { uid: 'a', fullName: 'Private name' });
  bucket.put('users/a/photos/portrait.jpg'); bucket.put('profile_images/a/registration/r/thumbs/one.jpg');
  db.put('users/b', { uid: 'b', status: 'active', fullName: 'Neighbor' });
  db.put('users/b/images/portrait', { url: photo('users/b/photos/portrait.jpg') });
  db.put('TOKENS/b', { token: 'neighbor-device-token' });
  db.put('chats/shared/chats/msg', { sendByID: 'a', message: 'Must remain' });
  db.put('meets/shared', { admin: 'a', users: ['a', 'b'] });
  db.put('users/a/received_gifts/receipt', { amount: 7 });
  db.put('payments/a', { amount: 27 });
  bucket.put('users/b/photos/portrait.jpg'); bucket.put('legacy-root-portrait.jpg');
  return { db, auth, bucket, input, options, backend };
}
const job = db => [...db.docs.entries()].find(([path]) => path.startsWith('_account_cleanup/'))?.[1]?.data;

test('disabled default performs zero Firestore/Auth/Storage work, including the Auth wrapper', async () => {
  const noAccess = new Proxy({}, { get() { throw new Error('unexpected access'); } });
  const backend = createAccountCleanup({ db: noAccess, auth: noAccess, bucket: noAccess });
  assert.deepEqual(await backend.cleanup({}), { status: 'disabled' });
  assert.deepEqual(await createAuthDeleteCleanupHandler({ backend: noAccess })({}, {}), { status: 'disabled' });
});

test('real deletion cleans the confirmed scope once and preserves finances, unknown fields, neighbors and shared content', async () => {
  const h = setup();
  const protectedPaths = ['users/b', 'users/b/images/portrait', 'TOKENS/b', 'chats/shared/chats/msg',
    'meets/shared', 'users/a/received_gifts/receipt', 'payments/a'];
  const before = protectedPaths.map(path => JSON.stringify(h.db.snapshot(path).data()));
  const result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'completed_scope'); assert.equal(result.removedDocuments, 5); assert.equal(result.removedPhotos, 2);
  const root = h.db.snapshot('users/a').data();
  assert.deepEqual(Object.keys(root).sort(), ['balance', 'deletionRequestedAt', 'gifts', 'isUnVisible', 'status', 'uid', 'unknownField'].sort());
  assert.equal(root.balance, 27); assert.equal(root.status, 'deleted'); assert.equal(root.deletionRequestedAt.toMillis(), REQUESTED);
  assert.deepEqual(protectedPaths.map(path => JSON.stringify(h.db.snapshot(path).data())), before);
  assert.ok(h.bucket.objects.has('users/b/photos/portrait.jpg')); assert.ok(h.bucket.objects.has('legacy-root-portrait.jpg'));
  assert.ok(h.auth.calls > result.removedDocuments);
  assert.equal((await h.backend.cleanup(h.input)).status, 'already_completed');
  assert.equal(h.bucket.removed.length, 2); assert.equal(h.db.deletes.length, 5);
});

test('an own server notification with sourceCreatedAt before the deletion cutoff is cleaned', async () => {
  const h = setup();
  h.db.put('users/a/notifications/server-notice', { type: 'friend_request', entityId: 'b',
    title: 'Request', body: '', read: false, actorUid: 'b',
    createdAt: stamp(REQUESTED - 1000), sourceCreatedAt: stamp(REQUESTED - 2000) });
  const result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'completed_scope'); assert.equal(result.skippedDocuments, 0);
  assert.equal(result.removedDocuments, 6); assert.equal(h.db.snapshot('users/a/notifications/server-notice').exists, false);
});

test('a missing real timestamp, mismatched UID, active root or stale Auth event cannot start cleanup', async () => {
  for (const patch of [{ deletionRequestedAt: REQUESTED }, { uid: 'b' }, { status: 'active' },
    { deletionRequestedAt: stamp(DELETED + 1000) }]) {
    const h = setup(); h.db.put('users/a', { ...h.db.snapshot('users/a').data(), ...patch }, REQUESTED);
    assert.equal((await h.backend.cleanup(h.input)).status, 'no_matching_tombstone');
    assert.equal(h.db.deletes.length, 0); assert.equal(h.bucket.removed.length, 0);
  }
  const h = setup(); h.input.createdAt = new Date(REQUESTED + 1000).toISOString();
  assert.equal((await h.backend.cleanup(h.input)).status, 'no_matching_tombstone');
});

test('an Auth account that still exists, even disabled, is never treated as deleted', async () => {
  const h = setup(); h.auth.existing.add('a');
  assert.equal((await h.backend.cleanup(h.input)).status, 'auth_uid_exists');
  assert.equal(h.db.deletes.length, 0); assert.equal(h.bucket.removed.length, 0); assert.equal(job(h.db), undefined);
});

test('partial Storage failure is retried safely without deleting a neighbor or repeating completed work', async () => {
  const h = setup(); let failed = false;
  h.bucket.beforeDelete = async name => {
    if (name.startsWith('profile_images/') && !failed) { failed = true; throw { code: 503, message: 'PRIVATE URL AND TOKEN' }; }
  };
  await assert.rejects(h.backend.cleanup(h.input), error => error.code === 'cleanup_unavailable' && !error.message.includes('PRIVATE'));
  assert.equal(job(h.db).status, 'partial'); assert.equal(h.bucket.removed.length, 1);
  assert.ok(h.db.snapshot('users/a').data().fullName);
  const result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'completed_scope'); assert.equal(h.bucket.removed.length, 2);
  assert.equal(h.db.deletes.length, 5); assert.ok(h.bucket.objects.has('users/b/photos/portrait.jpg'));
  assert.equal((await h.backend.cleanup(h.input)).status, 'already_completed');
});

test('parallel repeats reserve one cleanup attempt and do not double-delete resources', async () => {
  const h = setup();
  const results = await Promise.all([h.backend.cleanup(h.input), h.backend.cleanup(h.input)]);
  assert.deepEqual(results.map(result => result.status).sort(), ['completed_scope', 'in_progress']);
  assert.equal(h.bucket.removed.length, 2); assert.equal(h.db.deletes.length, 5);
});

test('a crash after lease commit causes the Auth wrapper to retry contention until expiry, then complete once', async () => {
  const h = setup();
  const runTransaction = h.db.runTransaction.bind(h.db);
  let crashed = false, taskNow = CLOCK;
  h.db.runTransaction = async run => {
    const result = await runTransaction(run);
    // Model a lost process/SDK result immediately after the lease was committed.
    // The caller never learns it claimed the job, so the live lease is retained.
    if (!crashed && result === 'claimed') {
      crashed = true; throw new Error('simulated loss after committed lease');
    }
    return result;
  };
  await assert.rejects(h.backend.cleanup(h.input), error => error.code === 'cleanup_unavailable');
  assert.equal(job(h.db).status, 'running'); assert.ok(job(h.db).lockId);
  assert.equal(h.db.deletes.length, 0); assert.equal(h.bucket.removed.length, 0);
  const backend = createAccountCleanup({ ...h.options, now: () => taskNow });
  const handler = createAuthDeleteCleanupHandler({ backend, enabled: () => true });
  const user = { uid: h.input.uid, metadata: { creationTime: h.input.createdAt } };
  const context = { eventId: h.input.eventId, timestamp: h.input.deletedAt };
  await assert.rejects(handler(user, context), error => error.message === 'account_cleanup_unavailable');
  assert.equal(job(h.db).status, 'running'); assert.equal(h.db.deletes.length, 0);
  assert.equal(h.bucket.removed.length, 0);
  taskNow = job(h.db).leaseUntilMs + 1;
  assert.equal((await handler(user, context)).status, 'completed_scope');
  assert.equal(job(h.db).status, 'completed_scope'); assert.equal(job(h.db).lockId, undefined);
  assert.equal(h.db.deletes.length, 5); assert.equal(h.bucket.removed.length, 2);
  assert.equal((await handler(user, context)).status, 'already_completed');
  assert.equal(h.db.deletes.length, 5); assert.equal(h.bucket.removed.length, 2);
});

test('recreated Auth UID during the run stops further deletion and keeps its newly written profile/data', async () => {
  const h = setup();
  h.auth.beforeGet = async (uid, call) => {
    if (call === 4) {
      h.auth.existing.add(uid);
      h.db.put('users/a', { uid: 'a', status: 'active', fullName: 'New account' }, CLOCK);
      h.db.put('users/a/images/new', { url: photo('users/a/photos/new.jpg') }, CLOCK);
      h.bucket.put('users/a/photos/new.jpg', '9', CLOCK);
    }
  };
  assert.equal((await h.backend.cleanup(h.input)).status, 'auth_uid_exists');
  assert.equal(h.db.snapshot('users/a').data().fullName, 'New account');
  assert.ok(h.db.snapshot('users/a/images/new').exists); assert.ok(h.db.snapshot('TOKENS/a').exists);
  assert.ok(h.bucket.objects.has('users/a/photos/new.jpg')); assert.equal(h.bucket.removed.length, 0);
  assert.equal((await h.backend.cleanup(h.input)).status, 'no_matching_tombstone');
});

test('recreation while photo metadata is read stops before deleting any generation', async () => {
  const h = setup();
  h.bucket.beforeMetadata = async name => {
    h.auth.existing.add('a'); h.bucket.put(name, 'new-generation', CLOCK);
  };
  assert.equal((await h.backend.cleanup(h.input)).status, 'auth_uid_exists');
  assert.equal(h.bucket.removed.length, 0); assert.equal(h.db.snapshot('users/a').data().fullName, 'Private name');
});

test('Storage generation change between eligibility check and deletion keeps the replacement photo', async () => {
  const h = setup();
  h.bucket.beforeDelete = async name => { if (name.startsWith('users/a/')) h.bucket.put(name, '2', CLOCK); };
  const result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'partial_scope'); assert.equal(result.skippedPhotos, 1);
  assert.equal(h.bucket.objects.get('users/a/photos/portrait.jpg').generation, '2');
});

test('a document concurrently rewritten after the tombstone survives the retried transaction', async () => {
  const h = setup(); let rewritten = false;
  h.db.beforeCommit = async ({ writes }) => {
    if (!rewritten && writes.some(write => write.kind === 'delete' && write.ref.path === 'TOKENS/a')) {
      rewritten = true; h.db.put('TOKENS/a', { token: 'new-installation' }, CLOCK);
    }
  };
  const result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'partial_scope'); assert.equal(result.skippedDocuments, 1);
  assert.equal(h.db.snapshot('TOKENS/a').data().token, 'new-installation');
});

test('UID proof and a common creation stamp are required before deleting another user request mirror', async () => {
  const h = setup(), createdAt = stamp(REQUESTED - 3000);
  h.db.put('users/a/friend_requests/b', { fromUid: 'b', status: 'pending', createdAt });
  h.db.put('users/b/friend_requests_sent/a', { toUid: 'a', status: 'pending', createdAt });
  h.db.put('users/a/friend_requests_sent/c', { toUid: 'c', status: 'pending', createdAt });
  h.db.put('users/c/friend_requests/a', { fromUid: 'neighbor', status: 'pending', createdAt });
  const result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'partial_scope');
  assert.equal(h.db.snapshot('users/a/friend_requests/b').exists, false);
  assert.equal(h.db.snapshot('users/b/friend_requests_sent/a').exists, false);
  assert.equal(h.db.snapshot('users/a/friend_requests_sent/c').exists, false);
  assert.equal(h.db.snapshot('users/c/friend_requests/a').data().fromUid, 'neighbor');
});

test('foreign UID, unknown/financial schema and malicious out-of-prefix Storage list entries are preserved', async () => {
  const h = setup();
  h.db.put('TOKENS/a', { uid: 'b', token: 'foreign' });
  h.db.put('private_users/a', { email: 'private@example.test', balance: 7 });
  h.db.put('users/a/notifications/unknown', { title: 'Keep', amount: 10 });
  h.bucket.listExtra = 'users/b/photos/portrait.jpg';
  const result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'partial_scope'); assert.equal(result.skippedDocuments, 3); assert.equal(result.skippedPhotos, 2);
  assert.equal(h.db.snapshot('TOKENS/a').data().uid, 'b'); assert.equal(h.db.snapshot('private_users/a').data().balance, 7);
  assert.equal(h.db.snapshot('users/a/notifications/unknown').data().amount, 10);
  assert.ok(h.bucket.objects.has('users/b/photos/portrait.jpg'));
});

test('legacy root filename remains untouched and unresolved token-free evidence survives repeats after profile scrub', async () => {
  const h = setup();
  h.db.put('users/a', { ...h.db.snapshot('users/a').data(), profilePic: photo('legacy-root-portrait.jpg') }, REQUESTED);
  let result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'partial_scope'); assert.equal(result.unresolvedPhotoReferences, 1);
  assert.ok(h.bucket.objects.has('legacy-root-portrait.jpg')); assert.equal(h.db.snapshot('users/a').data().profilePic, undefined);
  const first = job(h.db).unresolvedPhotoReferenceHashes;
  assert.equal(first.length, 1); assert.match(first[0], /^[a-f0-9]{64}$/);
  const serialized = JSON.stringify(job(h.db));
  for (const privateValue of ['private-download-token', 'legacy-root-portrait.jpg', 'Private name', 'private@example.test']) {
    assert.equal(serialized.includes(privateValue), false);
  }
  result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'partial_scope'); assert.equal(result.unresolvedPhotoReferences, 1);
  assert.deepEqual(job(h.db).unresolvedPhotoReferenceHashes, first); assert.equal(job(h.db).needsLegacyReview, true);
});

test('Firestore and Storage pagination continue beyond the first 100 deleted items', async () => {
  const h = setup();
  for (let n = 0; n < 205; n++) {
    const name = `extra-${String(n).padStart(4, '0')}`;
    h.db.put(`users/a/images/${name}`, { url: photo(`users/a/photos/${name}.jpg`) });
    h.bucket.put(`users/a/photos/${name}.jpg`);
  }
  const result = await h.backend.cleanup(h.input);
  assert.equal(result.status, 'completed_scope'); assert.equal(result.removedDocuments, 210); assert.equal(result.removedPhotos, 207);
  assert.ok(h.bucket.objects.has('legacy-root-portrait.jpg'));
});

test('Auth outages fail closed and an aborted late Auth result cannot start deletion', async () => {
  const outage = setup(); outage.auth.getUser = async () => { throw { code: 'auth/internal-error', message: 'PRIVATE CONTENT' }; };
  await assert.rejects(outage.backend.cleanup(outage.input), error => error.code === 'cleanup_auth_unavailable' && !error.message.includes('PRIVATE'));
  assert.equal(outage.db.deletes.length, 0);
  const h = setup(), controller = new AbortController(); let release, started;
  const pending = new Promise(resolve => { started = resolve; });
  h.auth.getUser = () => new Promise((resolve, reject) => { release = () => reject({ code: 'auth/user-not-found' }); started(); });
  const attempt = h.backend.cleanup({ ...h.input, signal: controller.signal });
  await pending; controller.abort(); release();
  await assert.rejects(attempt, error => error.code === 'cleanup_deadline');
  assert.equal(h.db.deletes.length, 0); assert.equal(h.bucket.removed.length, 0);
});

test('Auth event wrapper passes only the platform deletion identity and hides unsafe backend errors', async () => {
  let passed;
  const handler = createAuthDeleteCleanupHandler({ enabled: () => true, backend: { cleanup: async input => { passed = input; return { status: 'no_matching_tombstone' }; } } });
  await handler({ uid: 'a', email: 'private@example.test', metadata: { creationTime: 'creation' } }, { eventId: 'event', timestamp: 'deletion' });
  assert.equal(passed.uid, 'a'); assert.equal(passed.createdAt, 'creation'); assert.equal(passed.deletedAt, 'deletion');
  assert.equal(passed.email, undefined); assert.equal(passed.signal.aborted, true);
  const failing = createAuthDeleteCleanupHandler({ enabled: () => true, backend: { cleanup: async () => { throw new Error('PRIVATE URL'); } } });
  await assert.rejects(failing({}, {}), error => error.message === 'account_cleanup_unavailable');
});

test('installed SDK registers an Auth delete event, not a client endpoint or Firestore tombstone trigger', async () => {
  const prior = { project: process.env.GCLOUD_PROJECT, config: process.env.FIREBASE_CONFIG };
  process.env.GCLOUD_PROJECT = 'offline-cleanup-test';
  process.env.FIREBASE_CONFIG = JSON.stringify({ projectId: 'offline-cleanup-test', storageBucket: 'offline-bucket' });
  try {
    const { cleanupDeletedProfile } = await import('../src/account_cleanup_functions.js');
    assert.equal(cleanupDeletedProfile.__endpoint.eventTrigger.eventType, 'providers/firebase.auth/eventTypes/user.delete');
    assert.equal(cleanupDeletedProfile.__endpoint.httpsTrigger, undefined);
    assert.equal(cleanupDeletedProfile.__endpoint.eventTrigger.retry, true);
    assert.equal(cleanupDeletedProfile.__endpoint.platform, 'gcfv1');
  } finally {
    if (prior.project === undefined) delete process.env.GCLOUD_PROJECT; else process.env.GCLOUD_PROJECT = prior.project;
    if (prior.config === undefined) delete process.env.FIREBASE_CONFIG; else process.env.FIREBASE_CONFIG = prior.config;
  }
});
