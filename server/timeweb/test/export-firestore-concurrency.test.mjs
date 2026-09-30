import assert from 'node:assert/strict';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { randomBytes } from 'node:crypto';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { exportFirebase } from '../export-core.mjs';
import { parseArgs } from '../export-firebase-encrypted.mjs';
import { EncryptedArchiveWriter, readEncryptedArchive } from '../encrypted-archive.mjs';

const prefix = 'projects/test-project/databases/(default)/documents';
const record = (path) => ({ name: `${prefix}/${path}`, fields: { n: { integerValue: '1' } },
  createTime: '2026-09-25T00:00:00Z', updateTime: '2026-09-25T00:00:00Z' });

function fixture({ concurrency = 8, pages = 1000, fail = false } = {}) {
  const state = { activeReads: 0, peakReads: 0, reads: 0, activeWrites: 0,
    peakWrites: 0, aborted: false, finished: false, records: [], abortActive: null,
    startedCollections: [] };
  async function request(result, wait = 3) {
    state.reads++; state.activeReads++;
    state.peakReads = Math.max(state.peakReads, state.activeReads);
    try { await delay(wait); return result; }
    finally { state.activeReads--; }
  }
  const options = {
    auth: { listUsers: async () => ({ users: [] }) },
    firestoreApi: {
      listCollectionIds: async (parent) => request({ collectionIds: parent === ''
        ? Array.from({ length: 20 }, (_, i) => `c${i}`) : [] }),
      listDocuments: async (path) => {
        state.startedCollections.push(path);
        if (fail && path === 'c0') {
          await request(null, 1); throw new Error('synthetic first failure');
        }
        return request({ documents: [record(path + '/doc')] }, 8);
      },
    },
    writer: {
      writeJson: async (value) => {
        assert.equal(state.aborted, false);
        state.activeWrites++; state.peakWrites = Math.max(state.peakWrites, state.activeWrites);
        try { await delay(2); state.records.push(value); }
        finally { state.activeWrites--; }
      },
      finish: async (summary) => {
        assert.equal(state.activeReads, 0); assert.equal(state.activeWrites, 0);
        state.finished = true; state.summary = summary;
      },
      abort: async () => {
        state.aborted = true; state.abortActive = state.activeReads + state.activeWrites;
      },
    },
    project: 'test-project', database: '(default)', bucketName: 'test-bucket', scope: 'metadata',
    limits: { maxAuthUsers: 10, maxAuthListPages: 2,
      maxFirestoreCollections: 50, maxFirestoreReferences: 50,
      maxFirestoreListPages: pages, maxFirestoreConcurrency: concurrency },
  };
  return { state, options };
}

test('eight bounded readers produce the same counts with one serialized archive writer', async () => {
  const parallel = fixture();
  const sequential = fixture({ concurrency: 1 });
  const [a, b] = await Promise.all([exportFirebase(parallel.options), exportFirebase(sequential.options)]);
  assert.deepEqual(a, b);
  assert.equal(a.firestoreDocuments, 20);
  assert.equal(a.firestoreListPages, 41);
  assert.equal(parallel.state.peakReads, 8);
  assert.equal(sequential.state.peakReads, 1);
  assert.equal(parallel.state.peakWrites, 1);
  assert.equal(new Set(parallel.state.records.filter((r) => r.kind === 'firestore-document')
    .map((r) => r.path)).size, 20);
});

test('a newly queued orphan child starts while its large parent job is still reading', async () => {
  const { state, options } = fixture();
  let parentFinished = false;
  let childStartedEarly = false;
  options.firestoreApi.listCollectionIds = async (parent) => {
    if (!parent) return { collectionIds: ['root'] };
    if (parent === 'root/orphan') return { collectionIds: ['children'] };
    if (parent === 'root/second') { await delay(30); parentFinished = true; }
    return { collectionIds: [] };
  };
  options.firestoreApi.listDocuments = async (path) => {
    if (path === 'root') return { documents: [
      { name: prefix + '/root/orphan' }, record('root/second'),
    ] };
    childStartedEarly = !parentFinished;
    return { documents: [record('root/orphan/children/real')] };
  };
  const summary = await exportFirebase(options);
  assert.equal(childStartedEarly, true);
  assert.equal(summary.firestoreMissingParents, 1);
  assert.equal(summary.firestoreDocuments, 2);
  assert.equal(summary.firestoreReferences, 3);
  assert.ok(state.records.some((r) => r.path === 'root/orphan/children/real'));
});

test('parallel readers keep real AES-GCM frame order and completion intact', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-parallel-frames-'));
  const archive = join(directory, 'metadata.clrsenc');
  const key = randomBytes(32);
  const { options } = fixture();
  options.writer = await EncryptedArchiveWriter.create(archive, key);
  const summary = await exportFirebase(options);
  const records = [];
  for await (const frame of readEncryptedArchive(archive, key)) {
    assert.equal(frame.type, 'json'); records.push(frame.record);
  }
  assert.equal(records[0].firestoreConcurrency, 8);
  assert.equal(records.at(-1).kind, 'end');
  assert.deepEqual(records.at(-1).summary, summary);
  const paths = records.filter((r) => r.kind === 'firestore-document').map((r) => r.path);
  assert.equal(paths.length, 20);
  assert.equal(new Set(paths).size, 20);
});

test('first reader failure stops new jobs and drains active work before abort', async () => {
  const { state, options } = fixture({ fail: true });
  await assert.rejects(exportFirebase(options), /synthetic first failure/);
  assert.equal(state.startedCollections.length, 8);
  assert.equal(state.abortActive, 0);
  assert.equal(state.finished, false);
  assert.equal(state.aborted, true);
  const reads = state.reads;
  const written = state.records.length;
  await delay(20);
  assert.equal(state.reads, reads);
  assert.equal(state.records.length, written);
});

test('global read cap cannot be exceeded by parallel workers', async () => {
  const { state, options } = fixture({ pages: 12 });
  await assert.rejects(exportFirebase(options), /Firestore list-page limit reached/);
  assert.ok(state.reads <= 12);
  assert.equal(state.abortActive, 0);
  assert.equal(state.finished, false);
  assert.equal(state.peakWrites, 1);
});

test('writer failure drains readers and prevents pending frames after abort', async () => {
  const { state, options } = fixture();
  const original = options.writer.writeJson;
  options.writer.writeJson = async (value) => {
    if (value.kind === 'firestore-document') { await delay(4); throw new Error('synthetic frame failure'); }
    return original(value);
  };
  await assert.rejects(exportFirebase(options), /synthetic frame failure/);
  assert.equal(state.abortActive, 0);
  assert.equal(state.finished, false);
  assert.equal(state.records.filter((value) => value.kind === 'firestore-document').length, 0);
});

test('CLI defaults to one reader and accepts only integer concurrency 1 through 8', () => {
  const args = ['--project', 'test-project', '--bucket', 'test-bucket',
    '--out', '/tmp/f.clrsenc', '--key-file', '/tmp/k', '--scope', 'metadata',
    '--max-auth-users', '10', '--max-auth-list-pages', '2',
    '--max-firestore-collections', '10', '--max-firestore-references', '20',
    '--max-firestore-list-pages', '30', '--confirm-project', 'test-project',
    '--confirm-bucket', 'test-bucket', '--confirm-read-cost'];
  assert.equal(parseArgs(args).limits.maxFirestoreConcurrency, 1);
  assert.equal(parseArgs([...args, '--max-firestore-concurrency', '8']).limits.maxFirestoreConcurrency, 8);
  for (const value of ['0', '9', '1.5', '08', 'unsafe']) {
    assert.throws(() => parseArgs([...args, '--max-firestore-concurrency', value]));
  }
});
