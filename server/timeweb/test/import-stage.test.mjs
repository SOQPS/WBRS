import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtemp, readFile, stat, truncate, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { Readable } from 'node:stream';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { createPrivateS3MediaAdapter } from '../import-adapters.mjs';
import { scanImportArchive, targetObjectKey } from '../import-core.mjs';
import { stageImport, verifyStagedImport } from '../import-stage.mjs';

const source = {
  kind: 'source', format: 2, project: 'clrs-test', database: '(default)',
  bucket: 'clrs-test.appspot.com', scope: 'all', storagePrefix: '',
  completeSource: true, passwordHashesIncluded: false,
  snapshotConsistent: false,
};
const expectedSource = { project: source.project, database: source.database, bucket: source.bucket };
const fileBytes = Buffer.from('synthetic private image bytes');
const fileHash = createHash('sha256').update(fileBytes).digest('hex');
const metadata = {
  size: String(fileBytes.length), generation: '8234523', contentType: 'image/jpeg',
  metadata: { firebaseStorageDownloadTokens: 'synthetic-private-token' },
};
const typedFields = {
  count: { integerValue: '9007199254740993' },
  ref: { referenceValue: 'projects/clrs-test/databases/(default)/documents/users/u1' },
  when: { timestampValue: '2026-09-25T01:02:03.123456Z' },
  binary: { bytesValue: 'AAECAw==' },
};
const summary = {
  authUsers: 1, authListPages: 1, firestoreDocuments: 1,
  firestoreMissingParents: 1, firestoreReferences: 2,
  firestoreCollections: 2, firestoreListPages: 2,
  storageObjects: 1, storageBytes: fileBytes.length, storageListPages: 1,
};

async function archive({ sourceOverride = {}, wrongHash = false,
  key = randomBytes(32), authEmail = 'sample@example.invalid' } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-import-'));
  const archivePath = join(directory, 'source.clrsenc');
  const writer = await EncryptedArchiveWriter.create(archivePath, key);
  await writer.writeJson({ ...source, ...sourceOverride });
  await writer.writeJson({ kind: 'auth-user', user: {
    uid: 'u1', email: authEmail, customClaims: { admin: false },
  } });
  await writer.writeJson({ kind: 'firestore-document',
    path: 'users/u1/images/photo', fields: typedFields,
    createTime: '2026-09-24T01:00:00Z', updateTime: '2026-09-25T01:00:00Z',
  });
  await writer.writeJson({ kind: 'storage-object', name: 'avatars/u1.jpg', metadata });
  await writer.writeBytes(fileBytes);
  await writer.writeJson({ kind: 'storage-sha256', name: 'avatars/u1.jpg',
    sha256: wrongHash ? '0'.repeat(64) : fileHash });
  await writer.finish(summary);
  return { archivePath, key };
}

function fakeTargets() {
  const data = { auth: new Map(), documents: new Map(), objects: new Map(), source: null };
  let transaction;
  const calls = { begin: 0, commit: 0, rollback: 0, media: 0, verify: 0 };
  const clone = (map) => new Map(map);
  const upsertExact = (map, key, row) => {
    const previous = map.get(key);
    if (previous) assert.deepEqual(previous, row);
    else map.set(key, row);
  };
  return {
    calls, data,
    beforeWrite: async () => {},
    beforeCommit: async () => {},
    db: {
      async begin(newSource) {
        calls.begin++;
        if (data.source) assert.deepEqual(data.source, newSource);
        transaction = { source: newSource, auth: clone(data.auth),
          documents: clone(data.documents), objects: clone(data.objects) };
      },
      async stageAuth(row) { upsertExact(transaction.auth, row.uid, row); },
      async stageDocument(row) { upsertExact(transaction.documents, row.firebasePath, row); },
      async stageObject(row) { upsertExact(transaction.objects, row.name, row); },
      async commit() {
        calls.commit++;
        Object.assign(data, transaction);
        transaction = null;
      },
      async rollback() { calls.rollback++; transaction = null; },
    },
    media: {
      async ensure(row) {
        calls.media++;
        assert.equal(createHash('sha256').update(row.bytes).digest('hex'), row.sha256);
      },
      async verify(row) {
        calls.verify++;
        assert.equal(createHash('sha256').update(row.bytes).digest('hex'), row.sha256);
      },
    },
    verifier: {
      async begin(value) { assert.deepEqual(data.source, value); },
      async verifyAuth(row) { assert.deepEqual(data.auth.get(row.uid), row); },
      async verifyDocument(row) { assert.deepEqual(data.documents.get(row.firebasePath), row); },
      async verifyObject(row) { assert.deepEqual(data.objects.get(row.name), row); },
      async verifyCounts(counts) {
        assert.equal(data.auth.size, counts.authUsers);
        assert.equal(data.documents.size, counts.firestoreDocuments);
        assert.equal(data.objects.size, counts.storageObjects);
      },
      async commit() {},
      async rollback() {},
    },
  };
}

test('dry run validates a full encrypted source without touching targets', async () => {
  const input = await archive();
  const targets = fakeTargets();
  const result = await stageImport({ ...input, expectedSource, ...targets });
  assert.equal(result.imported, false);
  assert.deepEqual(result.counts, {
    authUsers: 1, firestoreDocuments: 1, storageObjects: 1, storageBytes: fileBytes.length,
  });
  assert.deepEqual(targets.calls, { begin: 0, commit: 0, rollback: 0, media: 0, verify: 0 });
});

test('staging preserves UID, typed orphan document, Storage metadata and hashes; retry is exact', async () => {
  const input = await archive();
  const targets = fakeTargets();
  await stageImport({ ...input, expectedSource, ...targets, dryRun: false });
  await stageImport({ ...input, expectedSource, ...targets, dryRun: false });
  assert.equal(targets.calls.commit, 2);
  assert.equal(targets.data.auth.size, 1);
  assert.equal(targets.data.documents.size, 1);
  assert.equal(targets.data.objects.size, 1);
  const doc = targets.data.documents.get('users/u1/images/photo');
  assert.equal(doc.parentPath, 'users/u1');
  assert.equal(doc.collectionPath, 'users/u1/images');
  assert.deepEqual(doc.encodedPayload.fields, typedFields);
  const object = targets.data.objects.get('avatars/u1.jpg');
  assert.deepEqual(object.metadata, metadata);
  assert.equal(object.sha256, fileHash);
  assert.equal(object.targetKey, targetObjectKey(source.project, source.bucket, object.name));
});

test('lost COMMIT acknowledgement requires explicit target verification and preserves its cause', async () => {
  const input = await archive(); const targets = fakeTargets();
  const commit = targets.db.commit;
  const lost = new Error('synthetic COMMIT acknowledgement lost');
  targets.db.commit = async () => { await commit(); throw lost; };
  targets.db.rollback = async () => { throw new Error('synthetic closed connection'); };
  await assert.rejects(stageImport({ ...input, expectedSource, ...targets, dryRun: false }),
    (error) => error.commitOutcomeUnknown === true && error.requiresVerification === true
      && error.cause === lost);
  assert.equal(targets.calls.commit, 1);
  const verified = await verifyStagedImport({ ...input, expectedSource,
    db: targets.verifier, media: targets.media, beforeRead: async () => {} });
  assert.equal(verified.verified, true);
  assert.equal(targets.data.auth.size, 1);
});

test('rollback failure does not replace the original pre-COMMIT failure', async () => {
  const input = await archive(); const targets = fakeTargets();
  const first = new Error('synthetic original media error');
  targets.media.ensure = async () => { throw first; };
  targets.db.rollback = async () => { throw new Error('synthetic rollback connection error'); };
  await assert.rejects(stageImport({ ...input, expectedSource, ...targets, dryRun: false }),
    (error) => error === first);
  assert.equal(targets.calls.commit, 0);
});

test('partial archive and wrong object checksum are rejected before DB/S3 writes', async () => {
  const partial = await archive();
  await truncate(partial.archivePath, (await stat(partial.archivePath)).size - 8);
  const targets = fakeTargets();
  await assert.rejects(stageImport({ ...partial, expectedSource, ...targets, dryRun: false }));
  const badHash = await archive({ wrongHash: true });
  await assert.rejects(stageImport({ ...badHash, expectedSource, ...targets, dryRun: false }),
    /Storage checksum/);
  assert.deepEqual(targets.calls, { begin: 0, commit: 0, rollback: 0, media: 0, verify: 0 });
});

test('a subset or different source is refused before staging', async () => {
  const subset = await archive({ sourceOverride: {
    scope: 'storage', completeSource: false, storagePrefix: 'avatars/',
  } });
  const targets = fakeTargets();
  await assert.rejects(stageImport({ ...subset, expectedSource, ...targets, dryRun: false }),
    /complete CLRSX2 source/);
  const complete = await archive();
  await assert.rejects(stageImport({ ...complete,
    expectedSource: { ...expectedSource, project: 'different' }, ...targets, dryRun: false }),
  /source does not match/);
  assert.equal(targets.calls.begin, 0);
});

test('independent read-only target verification catches a changed document', async () => {
  const input = await archive();
  const targets = fakeTargets();
  await stageImport({ ...input, expectedSource, ...targets, dryRun: false });
  const good = await verifyStagedImport({ ...input, expectedSource,
    db: targets.verifier, media: targets.media, beforeRead: async () => {} });
  assert.equal(good.verified, true);
  assert.equal(targets.calls.verify, 1);
  targets.data.documents.get('users/u1/images/photo').encodedPayload.fields.count.integerValue = '0';
  await assert.rejects(verifyStagedImport({ ...input, expectedSource,
    db: targets.verifier, media: targets.media, beforeRead: async () => {} }));
});

test('a complete same-count archive swapped after preflight is refused before DB commit', async () => {
  const key = randomBytes(32);
  const first = await archive({ key });
  const other = await archive({ key, authEmail: 'different@example.invalid' });
  const targets = fakeTargets();
  const original = await scanImportArchive(first);
  const alternate = await scanImportArchive(other);
  assert.deepEqual(original.summary, alternate.summary);
  assert.notEqual(original.archiveSha256, alternate.archiveSha256);
  await assert.rejects(stageImport({ ...first, expectedSource, ...targets,
    beforeWrite: async () => {
      await writeFile(first.archivePath, await readFile(other.archivePath));
    },
    dryRun: false,
  }), /Archive changed/);
  assert.equal(targets.calls.commit, 0);
  assert.equal(targets.calls.rollback, 1);
  assert.equal(targets.data.auth.size, 0);
});

test('S3 staging verifies bytes and MIME on first import and retry', async () => {
  const input = await archive();
  let record;
  await scanImportArchive({ ...input, onObject: (value) => { record = value; } });
  const objects = new Map();
  const calls = { put: 0, get: 0 };
  const client = {
    async send(command) {
      const request = command.input;
      if (command.constructor.name === 'GetObjectAclCommand') {
        if (!objects.has(request.Key)) throw { name: 'NoSuchKey', $metadata: { httpStatusCode: 404 } };
        return { Owner: { ID: 'owner' }, Grants: [{
          Permission: 'FULL_CONTROL', Grantee: { Type: 'CanonicalUser', ID: 'owner' },
        }] };
      }
      if (command.constructor.name === 'GetObjectCommand') {
        calls.get++;
        const stored = objects.get(request.Key);
        if (!stored) throw { name: 'NoSuchKey', $metadata: { httpStatusCode: 404 } };
        return { Body: Readable.from([stored.bytes]), ContentType: stored.type };
      }
      assert.equal(command.constructor.name, 'PutObjectCommand');
      assert.equal(request.IfNoneMatch, '*');
      assert.equal(request.Metadata['clrs-sha256'], fileHash);
      calls.put++;
      objects.set(request.Key, { bytes: request.Body, type: request.ContentType });
      return {};
    },
  };
  const media = createPrivateS3MediaAdapter(client, 'private-test-bucket');
  await media.ensure(record);
  await media.ensure(record);
  assert.equal(calls.put, 1);
  objects.get(record.targetKey).bytes = Buffer.from('wrong bytes');
  await assert.rejects(media.ensure(record), /checksum mismatch/);
});

test('archive encryption never persists the synthetic private values as plaintext', async () => {
  const input = await archive();
  const encrypted = await readFile(input.archivePath);
  assert.equal(encrypted.includes(fileBytes), false);
  assert.equal(encrypted.includes(Buffer.from('synthetic-private-token')), false);
});

test('CLI dry-run checks the source and prints counts without a database connection', async () => {
  const input = await archive();
  const keyPath = join(dirname(input.archivePath), 'key');
  await writeFile(keyPath, input.key, { mode: 0o600 });
  const script = fileURLToPath(new URL('../import-clrsx2.mjs', import.meta.url));
  const run = spawnSync(process.execPath, [script,
    '--archive', input.archivePath, '--key-file', keyPath,
    '--project', source.project, '--database', source.database,
    '--bucket', source.bucket, '--mode', 'dry-run',
  ], { encoding: 'utf8', env: { PATH: process.env.PATH } });
  assert.equal(run.status, 0, run.stderr);
  assert.deepEqual(JSON.parse(run.stdout), {
    mode: 'dry-run', authUsers: 1, firestoreDocuments: 1,
    storageObjects: 1, storageBytes: fileBytes.length,
  });
});
