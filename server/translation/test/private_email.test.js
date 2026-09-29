import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { createPrivateEmailLifecycle, createPrivateEmailAuthHandler } from '../src/private_email.js';
import { createAccountCleanup } from '../src/account_cleanup.js';

const CLOCK = Date.UTC(2026, 8, 28, 12), CREATED = CLOCK - 86400000;
const CREATE_HASH = createHash('sha256').update('trusted-event-one').digest('hex');
const REMOVE = Symbol('delete');
const stamp = ms => ({ seconds: Math.floor(ms / 1000), nanoseconds: (ms % 1000) * 1e6,
  toMillis() { return this.seconds * 1000 + this.nanoseconds / 1e6; } });
const clone = data => data?.toMillis ? stamp(data.toMillis()) : Array.isArray(data) ? data.map(clone) :
  data && typeof data === 'object' ? Object.fromEntries(Object.entries(data).map(([key, value]) => [key, clone(value)])) : data;
class Database {
  constructor() { this.docs = new Map(); this.version = 0; this.writes = []; this.reads = []; this.beforeCommit = null; }
  put(path, data, updated = CLOCK - 20000) {
    this.docs.set(path, { data: clone(data), version: ++this.version, updated });
  }
  snapshot(path) {
    const stored = this.docs.get(path);
    return { id: path.split('/').at(-1), ref: this.doc(path), exists: !!stored,
      data: () => stored ? clone(stored.data) : undefined,
      createTime: stored ? stamp(stored.updated) : undefined, updateTime: stored ? stamp(stored.updated) : undefined };
  }
  doc(path) { return { path, id: path.split('/').at(-1), get: async () => this.snapshot(path) }; }
  collection() { const query = { orderBy: () => query, limit: () => query,
    get: async () => ({ docs: [], size: 0 }) }; return query; }
  async runTransaction(run) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const reads = new Map(), writes = [];
      const result = await run({
        get: async ref => { this.reads.push(ref.path); reads.set(ref.path, this.docs.get(ref.path)?.version); return this.snapshot(ref.path); },
        set: (ref, data) => writes.push({ op: 'set', path: ref.path, data }),
        update: (ref, data) => writes.push({ op: 'update', path: ref.path, data }),
        delete: ref => writes.push({ op: 'delete', path: ref.path }),
      });
      const hook = this.beforeCommit; this.beforeCommit = null;
      if (hook) await hook({ reads, writes });
      if ([...reads].some(([path, version]) => this.docs.get(path)?.version !== version)) continue;
      for (const write of writes) {
        this.writes.push(clone(write));
        if (write.op === 'delete') { this.docs.delete(write.path); this.version++; continue; }
        const next = write.op === 'update' ? clone(this.docs.get(write.path).data) : {};
        for (const [key, value] of Object.entries(write.data)) {
          if (value === REMOVE) delete next[key]; else next[key] = clone(value);
        }
        this.put(write.path, next, CLOCK);
      }
      return result;
    }
    throw new Error('local_transaction_conflict');
  }
}
function setup() {
  const db = new Database();
  const auth = { calls: 0, user: { uid: 'a', email: 'Current@Example.test',
    metadata: { creationTime: new Date(CREATED).toUTCString() } }, beforeGet: null,
    async getUser() { this.calls++; if (this.beforeGet) await this.beforeGet(this.calls);
      if (!this.user) throw { code: 'auth/user-not-found' }; return clone(this.user); } };
  const input = { uid: 'a', createdAt: new Date(CREATED).toUTCString(),
    eventAt: new Date(CLOCK - 1000).toISOString(), eventId: 'trusted-event-one' };
  const backend = createPrivateEmailLifecycle({ db, auth, enabled: () => true, now: () => CLOCK });
  return { db, auth, input, backend };
}
const emailDoc = h => h.db.snapshot('private_users/a').data();

test('disabled provisioning and deletion perform zero Auth/Firestore work', async () => {
  const noAccess = new Proxy({}, { get() { throw new Error('unexpected access'); } });
  const backend = createPrivateEmailLifecycle({ db: noAccess, auth: noAccess });
  assert.deepEqual(await backend.provision({}), { status: 'disabled' });
  assert.deepEqual(await backend.remove({}), { status: 'disabled' });
  assert.deepEqual(await createPrivateEmailAuthHandler({ backend: noAccess, operation: 'provision' })({}, {}), { status: 'disabled' });
});
test('new account uses CURRENT Auth email and writes only private email/lifecycle fields', async () => {
  const h = setup();
  h.db.put('users/a', { uid: 'a', status: 'active', email: 'untrusted-client@example.test', balance: 123 });
  assert.equal((await h.backend.provision({ ...h.input, email: 'event-payload@example.test' })).status, 'provisioned');
  assert.deepEqual(emailDoc(h), { uid: 'a', email: 'current@example.test', authCreatedAtMs: CREATED, authCreateEventHash: CREATE_HASH });
  assert.deepEqual(h.db.writes.map(write => write.path), ['private_users/a']);
  assert.equal(h.db.snapshot('users/a').data().balance, 123);
});
test('email changed during request is taken from the late CURRENT Auth lookup', async () => {
  const h = setup(); h.auth.beforeGet = async calls => { if (calls === 2) h.auth.user.email = 'Latest@Example.test'; };
  await h.backend.provision(h.input); assert.equal(emailDoc(h).email, 'latest@example.test');
});
test('duplicate Auth create is idempotent without another paid Firestore write', async () => {
  const h = setup(); await h.backend.provision(h.input);
  assert.equal((await h.backend.provision(h.input)).status, 'already_provisioned');
  assert.equal(h.db.writes.length, 1);
});
test('different existing private email is an explicit conflict without overwrite', async () => {
  const h = setup(); h.db.put('private_users/a', { uid: 'a', email: 'other@example.test', authCreatedAtMs: CREATED, authCreateEventHash: CREATE_HASH });
  assert.equal((await h.backend.provision(h.input)).status, 'private_email_conflict');
  assert.equal(emailDoc(h).email, 'other@example.test'); assert.equal(h.db.writes.length, 0);
});
test('matching legacy private email without a trusted event fence requires owner review', async () => {
  for (const data of [{ email: 'current@example.test' },
    { uid: 'a', email: 'current@example.test', authCreatedAtMs: CREATED },
    { uid: 'a', email: 'current@example.test', authCreateEventHash: CREATE_HASH }]) {
    const h = setup(); h.db.put('private_users/a', data);
    assert.equal((await h.backend.provision(h.input)).status, 'legacy_private_requires_review');
    assert.deepEqual(emailDoc(h), data); assert.equal(h.db.writes.length, 0);
  }
});
test('unknown private fields or mismatched owner cannot be replaced', async () => {
  for (const data of [{ uid: 'b', email: 'current@example.test' }, { email: 'current@example.test', admin: true }]) {
    const h = setup(); h.db.put('private_users/a', data);
    assert.equal((await h.backend.provision(h.input)).status, 'private_owner_conflict'); assert.equal(h.db.writes.length, 0);
  }
});
test('foreign public profile owner prevents private provisioning', async () => {
  const h = setup(); h.db.put('users/a', { uid: 'b', status: 'active' });
  assert.equal((await h.backend.provision(h.input)).status, 'profile_owner_conflict'); assert.equal(h.db.writes.length, 0);
});
test('deleted, boolean-deleted and deletion-requested profiles all fence creation', async () => {
  for (const data of [{ status: 'deleted' }, { deleted: true }, { status: 'active', deletionRequestedAt: stamp(CLOCK - 10000) }]) {
    const h = setup(); h.db.put('users/a', { uid: 'a', ...data });
    assert.equal((await h.backend.provision(h.input)).status, 'deleted_profile'); assert.equal(h.db.writes.length, 0);
  }
});
test('cleanup lease is read using the actual timestamp-hashed cleanup key', async () => {
  const h = setup(), requested = stamp(CLOCK - 10000);
  const key = createHash('sha256').update(`a\0${requested.seconds}:${requested.nanoseconds}`).digest('hex');
  h.db.put('users/a', { uid: 'a', deletionRequestedAt: requested });
  h.db.put(`_account_cleanup/${key}`, { status: 'running', lockId: 'lease', leaseUntilMs: CLOCK + 10000 });
  assert.equal((await h.backend.provision(h.input)).status, 'cleanup_in_progress');
  assert.ok(h.db.reads.includes(`_account_cleanup/${key}`)); assert.equal(h.db.writes.length, 0);
});
test('Auth absence, disabled account and missing email never create a private record', async () => {
  for (const [user, status] of [[null, 'auth_absent'], [{ disabled: true }, 'auth_disabled'], [{ email: undefined }, 'auth_email_absent']]) {
    const h = setup(); h.auth.user = user === null ? null : { ...h.auth.user, ...user };
    assert.equal((await h.backend.provision(h.input)).status, status); assert.equal(h.db.writes.length, 0);
  }
});
test('Auth outage is retryable and cannot be misread as account absence', async () => {
  const h = setup(); h.auth.getUser = async () => { throw new Error('unsafe SDK details'); };
  await assert.rejects(h.backend.provision(h.input), { code: 'private_email_auth_unavailable' });
  await assert.rejects(h.backend.remove(h.input), { code: 'private_email_auth_unavailable' }); assert.equal(h.db.writes.length, 0);
});
test('invalid UID, event identity and timestamp do not start Auth queries', async () => {
  for (const patch of [{ uid: '../b' }, { uid: '' }, { eventId: '' }, { createdAt: 'bad' },
    { eventAt: new Date(CLOCK + 60001).toISOString() }]) {
    const h = setup(); assert.equal((await h.backend.provision({ ...h.input, ...patch })).status, 'invalid_auth_event');
    assert.equal(h.auth.calls, 0); assert.equal(h.db.writes.length, 0);
  }
});
test('aborted late Auth lookup never begins a private write', async () => {
  const h = setup(), controller = new AbortController(); h.auth.beforeGet = async () => controller.abort();
  await assert.rejects(h.backend.provision({ ...h.input, signal: controller.signal }), { code: 'private_email_deadline' });
  assert.equal(h.db.writes.length, 0);
});
test('different current Auth creation time fences a stale create event', async () => {
  const h = setup(); h.auth.user.metadata.creationTime = new Date(CREATED + 1000).toUTCString();
  assert.equal((await h.backend.provision(h.input)).status, 'auth_generation_changed'); assert.equal(h.db.writes.length, 0);
});
test('UID replacement during late Auth check prevents the earlier create write', async () => {
  const h = setup(); h.auth.beforeGet = async calls => { if (calls === 2) h.auth.user.metadata.creationTime = new Date(CREATED + 1000).toUTCString(); };
  assert.equal((await h.backend.provision(h.input)).status, 'auth_generation_changed'); assert.equal(h.db.writes.length, 0);
});
test('direct Auth deletion atomically removes email and creates a persistent private marker', async () => {
  const h = setup(); await h.backend.provision(h.input); h.auth.user = null;
  assert.equal((await h.backend.remove(h.input)).status, 'deleted_uid_fenced');
  assert.deepEqual(emailDoc(h), { uid: 'a', authCreatedAtMs: CREATED, status: 'auth_deleted', authCreateEventHash: CREATE_HASH });
  assert.equal((await h.backend.remove(h.input)).status, 'already_fenced'); assert.equal(h.db.writes.length, 2);
});
test('delete arriving before delayed create fences even an absent private document', async () => {
  const h = setup(); h.auth.user = null;
  await h.backend.remove(h.input);
  // A controlled stale/current lookup cannot bypass a durable UID marker.
  h.auth.user = { uid: 'a', email: 'current@example.test', metadata: { creationTime: h.input.createdAt } };
  assert.equal((await h.backend.provision(h.input)).status, 'deleted_uid_requires_review');
  assert.equal(emailDoc(h).email, undefined); assert.equal(h.db.writes.length, 1);
});
test('direct delete between creator read and commit forces retry against the private marker', async () => {
  const h = setup(); h.db.beforeCommit = async () => { h.auth.user = null; await h.backend.remove(h.input); };
  assert.equal((await h.backend.provision(h.input)).status, 'deleted_uid_requires_review');
  assert.deepEqual(emailDoc(h), { uid: 'a', authCreatedAtMs: CREATED, status: 'auth_deleted' });
  assert.equal(h.db.writes.length, 1);
});
test('normal app deletion removes only private generation while retaining the users tombstone', async () => {
  const h = setup(); await h.backend.provision(h.input); h.auth.user = null;
  h.db.put('users/a', { uid: 'a', status: 'deleted', deletionRequestedAt: stamp(CLOCK - 10000), balance: 27 });
  assert.equal((await h.backend.remove(h.input)).status, 'tombstone_fenced'); assert.equal(emailDoc(h), undefined);
  assert.equal(h.db.snapshot('users/a').data().status, 'deleted'); assert.equal(h.db.snapshot('users/a').data().balance, 27);
});
test('old delete never touches a current reused UID, including same-second SDK timestamps', async () => {
  for (const delta of [0, 1000]) {
    const h = setup(); h.auth.user.metadata.creationTime = new Date(CREATED + delta).toUTCString();
    const data = { uid: 'a', email: 'new@example.test', authCreatedAtMs: CREATED + delta };
    h.db.put('private_users/a', data);
    assert.equal((await h.backend.remove(h.input)).status, 'auth_uid_exists');
    assert.deepEqual(emailDoc(h), data); assert.equal(h.db.writes.length, 0);
  }
});
test('same-second same-email UID recreation before delayed delete requires a distinct create event review', async () => {
  const h = setup(); await h.backend.provision(h.input);
  const before = emailDoc(h), writesBefore = h.db.writes.length;
  // A recreated current UserRecord is indistinguishable by SDK time/email.
  h.auth.user = { uid: 'a', email: 'Current@Example.test', metadata: { creationTime: h.input.createdAt } };
  assert.equal((await h.backend.provision({ ...h.input, eventId: 'trusted-create-event-two' })).status, 'private_event_requires_review');
  assert.equal((await h.backend.remove({ ...h.input, eventId: 'delayed-delete-event-one' })).status, 'auth_uid_exists');
  assert.deepEqual(emailDoc(h), before); assert.equal(h.db.writes.length, writesBefore);
});
test('late reused Auth account aborts deletion without altering its private data', async () => {
  const h = setup(); h.auth.user = null;
  h.db.put('private_users/a', { uid: 'a', email: 'current@example.test', authCreatedAtMs: CREATED, authCreateEventHash: CREATE_HASH });
  h.auth.beforeGet = async calls => { if (calls === 2) h.auth.user = { uid: 'a', email: 'new@example.test', metadata: { creationTime: new Date(CREATED + 1000).toUTCString() } }; };
  assert.equal((await h.backend.remove(h.input)).status, 'auth_uid_exists'); assert.equal(h.db.writes.length, 0);
});
test('different private generation is never deleted when Auth is absent', async () => {
  const h = setup(); h.auth.user = null;
  h.db.put('private_users/a', { uid: 'a', email: 'new@example.test', authCreatedAtMs: CREATED + 1000, authCreateEventHash: CREATE_HASH });
  assert.equal((await h.backend.remove(h.input)).status, 'private_generation_conflict'); assert.equal(h.db.writes.length, 0);
});
test('permanent marker cannot be lifted automatically by a newer Auth creation date', async () => {
  const h = setup(); h.db.put('private_users/a', { uid: 'a', authCreatedAtMs: CREATED, status: 'auth_deleted' });
  const newTime = new Date(CREATED + 1000).toUTCString(); h.auth.user.metadata.creationTime = newTime;
  assert.equal((await h.backend.provision({ ...h.input, createdAt: newTime })).status, 'deleted_uid_requires_review');
  assert.equal(h.db.writes.length, 0);
});
test('delete preserves migrated private email without proven Auth generation', async () => {
  const h = setup(); h.auth.user = null; h.db.put('private_users/a', { email: 'legacy@example.test' });
  assert.equal((await h.backend.remove(h.input)).status, 'legacy_private_requires_review');
  assert.equal(emailDoc(h).email, 'legacy@example.test'); assert.equal(h.db.writes.length, 0);
});
test('Auth event wrapper passes platform identity, reports safe conflicts and redacts SDK failures', async () => {
  const reports = [], h = setup(); let captured;
  const handler = createPrivateEmailAuthHandler({ enabled: () => true, operation: 'provision',
    backend: { async provision(input) { captured = input; return { status: 'private_email_conflict' }; } }, report: safe => reports.push(safe) });
  await handler({ uid: 'a', email: 'never-pass@example.test', metadata: { creationTime: h.input.createdAt } },
    { timestamp: h.input.eventAt, eventId: h.input.eventId });
  assert.equal(captured.email, undefined); assert.equal(captured.uid, 'a'); assert.equal(captured.eventId, h.input.eventId);
  assert.deepEqual(reports, [{ operation: 'provision', status: 'private_email_conflict' }]);
  await assert.rejects(createPrivateEmailAuthHandler({ enabled: () => true, operation: 'remove',
    backend: { async remove() { throw new Error('private UID/email SDK detail'); } } })({}, {}), { message: 'private_email_unavailable' });
});
test('real Auth SDK wrapper forwards trusted context eventId to the lifecycle backend', async () => {
  const previousProject = process.env.GCLOUD_PROJECT;
  process.env.GCLOUD_PROJECT = 'offline-private-email-wrapper';
  try {
  const { region } = await import('firebase-functions/v1');
  const h = setup(); let captured;
  const sdkFunction = region('europe-west1').auth.user().onCreate(createPrivateEmailAuthHandler({
    enabled: () => true, operation: 'provision', backend: { async provision(input) {
      captured = input; return { status: 'provisioned' };
    } },
  }));
  await sdkFunction.run({ uid: 'a', email: 'untrusted-event@example.test', metadata: { creationTime: h.input.createdAt } },
    { timestamp: h.input.eventAt, eventId: 'unique-platform-create-event' });
  assert.equal(captured.eventId, 'unique-platform-create-event'); assert.equal(captured.email, undefined);
  assert.equal(captured.uid, 'a'); assert.equal(sdkFunction.__endpoint.eventTrigger.eventType,
    'providers/firebase.auth/eventTypes/user.create');
  } finally {
    if (previousProject === undefined) delete process.env.GCLOUD_PROJECT;
    else process.env.GCLOUD_PROJECT = previousProject;
  }
});

async function cleanupNewPrivate(data) {
  const h = setup(); h.auth.user = null;
  h.db.put('users/a', { uid: 'a', status: 'deleted', deletionRequestedAt: stamp(CLOCK - 10000) });
  h.db.put('private_users/a', data);
  const backend = createAccountCleanup({ db: h.db, auth: h.auth, enabled: () => true, now: () => CLOCK,
    timestamp: () => stamp(CLOCK), deleteField: () => REMOVE,
    bucket: { name: 'offline-bucket', getFiles: async () => [[], null] } });
  const result = await backend.cleanup({ uid: 'a', eventId: 'trusted-delete', createdAt: h.input.createdAt,
    deletedAt: new Date(CLOCK - 5000).toISOString() });
  return { h, result };
}
test('existing cleanup accepts the new private Auth generation metadata', async () => {
  const { h, result } = await cleanupNewPrivate({ uid: 'a', email: 'current@example.test', authCreatedAtMs: CREATED, authCreateEventHash: CREATE_HASH });
  assert.equal(result.status, 'completed_scope'); assert.equal(emailDoc(h), undefined);
});
test('existing cleanup deliberately preserves the permanent no-email private marker', async () => {
  const data = { uid: 'a', authCreatedAtMs: CREATED, status: 'auth_deleted' };
  const { h, result } = await cleanupNewPrivate(data);
  assert.equal(result.status, 'partial_scope'); assert.deepEqual(emailDoc(h), data);
});
test('installed SDK exports two bounded trusted lifecycle events, disabled with no secrets/network', async () => {
  process.env.GCLOUD_PROJECT = 'offline-private-email'; process.env.CLRS_PRIVATE_EMAIL_PROVISION_ENABLED = 'false';
  const exports = await import('../src/private_email_functions.js');
  for (const [name, operation] of [['provisionPrivateEmail', 'create'], ['fenceDeletedPrivateEmail', 'delete']]) {
    const fn = exports[name], endpoint = fn.__endpoint;
    assert.equal(endpoint.platform, 'gcfv1'); assert.equal(endpoint.timeoutSeconds, 30);
    assert.equal(endpoint.minInstances, 0); assert.equal(endpoint.maxInstances, 1);
    assert.equal(endpoint.eventTrigger.eventType, `providers/firebase.auth/eventTypes/user.${operation}`);
    assert.equal(endpoint.eventTrigger.retry, true); assert.equal(endpoint.httpsTrigger, undefined);
    assert.deepEqual(endpoint.secretEnvironmentVariables || [], []);
    assert.deepEqual(await fn.run({}, {}), { status: 'disabled' });
  }
});
