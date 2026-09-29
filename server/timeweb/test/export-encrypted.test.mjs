import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { appendFile, mkdir, mkdtemp, readdir, readFile, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter, readEncryptedArchive } from '../encrypted-archive.mjs';
import { exportFirebase } from '../export-core.mjs';
import { parseArgs } from '../export-firebase-encrypted.mjs';
import { validateExportPaths } from '../export-paths.mjs';
import { scanImportArchive } from '../import-core.mjs';

const limits = {
  maxAuthUsers: 10, maxAuthListPages: 10, maxFirestoreCollections: 10,
  maxFirestoreReferences: 10, maxFirestoreListPages: 20,
  maxStorageObjects: 10, maxStorageListPages: 10,
  maxStorageBytes: 1024,
};
const prefix = 'projects/test-project/databases/(default)/documents';
const typedFields = {
  count: { integerValue: '9007199254740993' },
  ratio: { doubleValue: 1.5 },
  when: { timestampValue: '2026-09-25T01:02:03.123456Z' },
  where: { geoPointValue: { latitude: 55.75, longitude: 37.62 } },
  ref: { referenceValue: `${prefix}/users/u1` },
  binary: { bytesValue: 'AAECAw==' },
  nested: { mapValue: { fields: { names: { arrayValue: {
    values: [{ stringValue: 'private text' }, { nullValue: null }],
  } } } } },
};

function fakeSources({ failStorage = false } = {}) {
  const content = Buffer.from('private image bytes');
  return {
    auth: {
      async listUsers() {
        return { users: [{ uid: 'u1', toJSON: () => ({
          uid: 'u1', email: 'private@example.test', customClaims: { admin: false },
          passwordHash: 'must-not-export', passwordSalt: 'must-not-export',
        }) }] };
      },
    },
    firestoreApi: {
      async listCollectionIds(parent) {
        return { collectionIds: ({
          '': ['users', 'old'],
          'users/u1': ['images'],
          'old/orphan': ['children'],
        })[parent] ?? [] };
      },
      async listDocuments(collection) {
        const document = (path, fields) => ({
          name: `${prefix}/${path}`, fields,
          createTime: '2026-09-24T01:00:00Z',
          updateTime: '2026-09-25T01:00:00Z',
        });
        return { documents: ({
          users: [document('users/u1', typedFields)],
          old: [{ name: `${prefix}/old/orphan` }],
          'users/u1/images': [document('users/u1/images/photo', {
            filename: { stringValue: 'image.jpg' },
          })],
          'old/orphan/children': [document('old/orphan/children/real', {
            value: { booleanValue: true },
          })],
        })[collection] ?? [] };
      },
    },
    bucket: {
      async getFiles() {
        return [[{ name: 'avatars/u1.jpg', metadata: {
          size: String(content.length), generation: '123', contentType: 'image/jpeg',
          metadata: { firebaseStorageDownloadTokens: 'private-token' },
        } }], null];
      },
      file(name, options) {
        assert.equal(name, 'avatars/u1.jpg');
        assert.equal(options.generation, '123');
        return { async *createReadStream() {
          yield content.subarray(0, 5);
          if (failStorage) throw new Error('synthetic read failure');
          yield content.subarray(5);
        } };
      },
    },
    content,
  };
}

async function frames(path, key) {
  const result = [];
  for await (const frame of readEncryptedArchive(path, key)) result.push(frame);
  return result;
}

test('encrypted full export preserves typed Firestore values and orphan descendants', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-export-test-'));
  const path = join(dir, 'export.clrsenc');
  const key = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(path, key);
  const source = fakeSources();
  const summary = await exportFirebase({
    ...source, writer, project: 'test-project', bucketName: 'test-bucket', limits,
  });
  assert.equal(summary.authUsers, 1);
  assert.equal(summary.firestoreDocuments, 3);
  assert.equal(summary.firestoreMissingParents, 1);
  assert.equal(summary.storageObjects, 1);
  assert.equal(summary.storageBytes, source.content.length);
  assert.equal((await stat(path)).mode & 0o077, 0);
  const encrypted = await readFile(path);
  assert.equal(encrypted.includes(Buffer.from('private text')), false);
  const restored = await frames(path, key);
  const records = restored.filter((row) => row.type === 'json').map((row) => row.record);
  assert.deepEqual(records.find((row) => row.path === 'users/u1').fields, typedFields);
  assert.ok(records.some((row) => row.path === 'old/orphan/children/real'));
  assert.ok(!records.some((row) => row.path === 'old/orphan'));
  assert.equal(records.find((row) => row.kind === 'auth-user').user.passwordHash, undefined);
  assert.equal(records.find((row) => row.kind === 'auth-user').user.passwordSalt, undefined);
  assert.deepEqual(Buffer.concat(restored.filter((row) => row.type === 'bytes')
    .map((row) => row.bytes)), source.content);
  assert.equal(records.at(-1).kind, 'end');
});

test('a failed byte stream leaves no published or partial archive', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-export-fail-'));
  const path = join(dir, 'export.clrsenc');
  const writer = await EncryptedArchiveWriter.create(path, randomBytes(32));
  await assert.rejects(exportFirebase({
    ...fakeSources({ failStorage: true }), writer,
    project: 'test-project', bucketName: 'test-bucket',
    scope: 'storage', storagePrefix: 'avatars/', limits,
  }), /synthetic read failure/);
  assert.deepEqual(await readdir(dir), []);
});

test('storage-only subset is labelled incomplete and tampering is detected', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-export-subset-'));
  const path = join(dir, 'subset.clrsenc');
  const key = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(path, key);
  await exportFirebase({
    ...fakeSources(), writer, project: 'test-project', bucketName: 'test-bucket',
    scope: 'storage', storagePrefix: 'avatars/', limits,
  });
  const source = (await frames(path, key))[0].record;
  assert.equal(source.completeSource, false);
  assert.equal(source.storagePrefix, 'avatars/');
  const encrypted = await readFile(path);
  encrypted[30] ^= 1;
  await writeFile(path, encrypted);
  await assert.rejects(frames(path, key));
});

test('metadata export encrypts Auth and Firestore without reading Storage and cannot be imported as complete', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-export-metadata-'));
  const archivePath = join(dir, 'metadata.clrsenc');
  const key = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(archivePath, key);
  const source = fakeSources();
  const summary = await exportFirebase({
    ...source, bucket: undefined, writer, project: 'test-project', bucketName: 'test-bucket',
    scope: 'metadata', limits: {
      maxAuthUsers: limits.maxAuthUsers,
      maxAuthListPages: limits.maxAuthListPages,
      maxFirestoreCollections: limits.maxFirestoreCollections,
      maxFirestoreReferences: limits.maxFirestoreReferences,
      maxFirestoreListPages: limits.maxFirestoreListPages,
    },
  });
  assert.equal(summary.authUsers, 1);
  assert.equal(summary.firestoreDocuments, 3);
  assert.equal(summary.firestoreMissingParents, 1);
  assert.equal(summary.storageObjects, 0);
  assert.equal(summary.storageBytes, 0);
  assert.equal(summary.storageListPages, 0);
  assert.equal((await stat(archivePath)).mode & 0o077, 0);
  const encrypted = await readFile(archivePath);
  assert.equal(encrypted.includes(Buffer.from('private text')), false);
  assert.equal(encrypted.includes(Buffer.from('private@example.test')), false);
  const restored = await frames(archivePath, key);
  assert.equal(restored.some((frame) => frame.type === 'bytes'), false);
  const records = restored.map((frame) => frame.record);
  assert.equal(records[0].scope, 'metadata');
  assert.equal(records[0].completeSource, false);
  assert.equal(records[0].storagePrefix, '');
  assert.equal(records[0].project, 'test-project');
  assert.equal(records[0].bucket, 'test-bucket');
  assert.deepEqual(records.find((record) => record.path === 'users/u1').fields, typedFields);
  assert.equal(records.find((record) => record.kind === 'auth-user').user.passwordHash, undefined);
  assert.equal(records.some((record) => record.kind === 'storage-object'), false);
  assert.equal(records.at(-1).kind, 'end');
  let imported = false;
  await assert.rejects(scanImportArchive({
    archivePath, key,
    onAuth: () => { imported = true; },
    onDocument: () => { imported = true; },
    onObject: () => { imported = true; },
  }), /complete CLRSX2 source/);
  assert.equal(imported, false);
});

test('metadata CLI has explicit read bounds and refuses a Storage prefix', () => {
  const args = [
    '--project', 'test-project', '--bucket', 'test-bucket',
    '--out', '/tmp/metadata.clrsenc', '--key-file', '/tmp/export.key',
    '--scope', 'metadata', '--max-auth-users', '10', '--max-auth-list-pages', '2',
    '--max-firestore-collections', '10', '--max-firestore-references', '20',
    '--max-firestore-list-pages', '30',
    '--confirm-project', 'test-project', '--confirm-bucket', 'test-bucket',
    '--confirm-read-cost',
  ];
  const parsed = parseArgs(args);
  assert.equal(parsed.scope, 'metadata');
  assert.equal(parsed.limits.maxStorageBytes, undefined);
  assert.equal(parsed.limits.maxFirestoreListPages, 30);
  assert.throws(() => parseArgs([...args, '--storage-prefix', 'avatars/']),
    /storage prefix/);
  assert.throws(() => parseArgs(args.filter((arg) => arg !== '--confirm-read-cost')),
    /confirmation required/);
  const missingFirestoreLimit = [...args];
  missingFirestoreLimit.splice(missingFirestoreLimit.indexOf('--max-firestore-list-pages'), 2);
  assert.throws(() => parseArgs(missingFirestoreLimit),
    /Missing --max-firestore-list-pages/);
  assert.throws(() => parseArgs(args.map((arg) => arg === 'metadata' ? 'all' : arg)),
    /Missing --max-storage-objects/);
  assert.throws(() => parseArgs(args.map((arg) => arg === 'metadata' ? 'storage' : arg)),
    /Missing --max-storage-objects/);
});

test('metadata export removes the partial file when a Firestore read limit is reached', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-export-metadata-limit-'));
  const path = join(dir, 'metadata.clrsenc');
  const writer = await EncryptedArchiveWriter.create(path, randomBytes(32));
  const source = fakeSources();
  await assert.rejects(exportFirebase({
    ...source, bucket: undefined, writer, project: 'test-project',
    bucketName: 'test-bucket', scope: 'metadata',
    limits: { ...limits, maxFirestoreListPages: 1 },
  }), /Firestore list-page limit reached/);
  assert.deepEqual(await readdir(dir), []);
});

test('empty Auth pages still obey the explicit request limit', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-export-auth-limit-'));
  const path = join(dir, 'export.clrsenc');
  const writer = await EncryptedArchiveWriter.create(path, randomBytes(32));
  const source = fakeSources();
  let requests = 0;
  source.auth.listUsers = async () => ({
    users: [], pageToken: `page-${++requests}`,
  });
  await assert.rejects(exportFirebase({
    ...source, writer, project: 'test-project', bucketName: 'test-bucket',
    limits: { ...limits, maxAuthListPages: 2 },
  }), /Auth list-page limit reached/);
  assert.equal(requests, 2);
  assert.deepEqual(await readdir(dir), []);
});

test('export paths resolve symlinks and inside names beginning with two dots', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-export-paths-'));
  const root = join(dir, 'repository');
  const outside = join(dir, 'outside');
  await mkdir(root);
  await mkdir(outside);
  await mkdir(join(root, '..hidden'));
  const privateKey = join(outside, 'key');
  const insideKey = join(root, 'key');
  await writeFile(privateKey, randomBytes(32), { mode: 0o600 });
  await writeFile(insideKey, randomBytes(32), { mode: 0o600 });
  await symlink(root, join(outside, 'repository-link'));
  await assert.rejects(validateExportPaths(
    root, join(outside, 'repository-link', 'archive'), privateKey,
  ), /outside the repository/);
  await assert.rejects(validateExportPaths(
    root, join(outside, 'archive'), join(outside, 'repository-link', 'key'),
  ), /outside the repository/);
  await assert.rejects(validateExportPaths(
    root, join(root, '..hidden', 'archive'), privateKey,
  ), /outside the repository/);
});

test('a completion marker is not exposed before trailing bytes are rejected', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-export-trailing-'));
  const path = join(dir, 'export.clrsenc');
  const key = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(path, key);
  await writer.writeJson({ kind: 'source' });
  await writer.finish({});
  await appendFile(path, Buffer.from([0]));
  let sawEnd = false;
  await assert.rejects(async () => {
    for await (const frame of readEncryptedArchive(path, key)) {
      if (frame.record?.kind === 'end') {
        sawEnd = true;
        break;
      }
    }
  }, /trailing data/);
  assert.equal(sawEnd, false);
});
