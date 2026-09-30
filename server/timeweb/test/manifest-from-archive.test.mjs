import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { Timestamp, GeoPoint } from 'firebase-admin/firestore';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { collectManifest, compareManifests, fingerprint } from '../manifest.mjs';
import { collectArchiveManifest, decodeArchiveFields } from '../manifest-from-archive.mjs';

const fields = {
  count: { integerValue: '9007199254740993' },
  when: { timestampValue: '2026-09-25T01:02:03.123456789Z' },
  where: { geoPointValue: { latitude: 55.75, longitude: 37.62 } },
  ref: { referenceValue: 'projects/test-project/databases/(default)/documents/users/u1' },
  binary: { bytesValue: 'AAECAw==' },
  nested: { mapValue: { fields: { values: { arrayValue: { values: [
    { doubleValue: 'NaN' }, { booleanValue: true }, { nullValue: null },
    { stringValue: 'PRIVATE CONTENT' },
  ] } } } } },
};

function fixtureDocument(path, data, children = []) {
  return { path, id: path.split('/').at(-1),
    get: async () => ({ exists: data !== null, data: () => data }),
    listCollections: async () => children };
}
const fixtureCollection = (id, documents) => ({ id, listDocuments: async () => documents });

test('local full-archive manifest matches the Admin SDK inventory, including orphan descendants', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-local-manifest-'));
  const archivePath = join(directory, 'full.clrsenc');
  const archiveKey = randomBytes(32);
  const hmacKey = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(archivePath, archiveKey);
  const user = { uid: 'u1', email: 'private@example.invalid', emailVerified: true,
    customClaims: { admin: true }, providerData: [{ providerId: 'password' }] };
  const image = Buffer.from('PRIVATE IMAGE BYTES');
  const metadata = { size: String(image.length), generation: '123',
    md5Hash: createHash('md5').update(image).digest('base64') };
  await writer.writeJson({ kind: 'source', format: 2, project: 'test-project',
    database: '(default)', bucket: 'test-bucket', scope: 'all', completeSource: true,
    storagePrefix: '', passwordHashesIncluded: false });
  await writer.writeJson({ kind: 'auth-user', user });
  await writer.writeJson({ kind: 'firestore-document', path: 'users/u1', fields,
    createTime: '2026-09-25T00:00:00Z', updateTime: '2026-09-25T00:00:00Z' });
  await writer.writeJson({ kind: 'firestore-document', path: 'old/missing/children/child',
    fields: { sendByID: { stringValue: 'missing-auth' } },
    createTime: '2026-09-25T00:00:00Z', updateTime: '2026-09-25T00:00:00Z' });
  await writer.writeJson({ kind: 'storage-object', name: 'image.jpg', metadata });
  await writer.writeBytes(image);
  await writer.writeJson({ kind: 'storage-sha256', name: 'image.jpg',
    sha256: createHash('sha256').update(image).digest('hex') });
  await writer.finish({ authUsers: 1, authListPages: 1, firestoreDocuments: 2,
    firestoreMissingParents: 1, firestoreReferences: 3, firestoreCollections: 3,
    firestoreListPages: 7, storageObjects: 1, storageBytes: image.length, storageListPages: 1 });
  const result = await collectArchiveManifest({ archivePath, archiveKey, hmacKey });
  const sdkData = {
    count: Number('9007199254740993'),
    when: new Timestamp(Date.parse('2026-09-25T01:02:03Z') / 1000, 123456789),
    where: new GeoPoint(55.75, 37.62),
    ref: { path: 'users/u1', firestore: {} },
    binary: Buffer.from('AAECAw==', 'base64'),
    nested: { values: [NaN, true, null, 'PRIVATE CONTENT'] },
  };
  const baseline = await collectManifest({
    auth: { listUsers: async () => ({ users: [user] }) },
    firestore: { listCollections: async () => [
      fixtureCollection('users', [fixtureDocument('users/u1', sdkData)]),
      fixtureCollection('old', [fixtureDocument('old/missing', null, [
        fixtureCollection('children', [fixtureDocument('old/missing/children/child', { sendByID: 'missing-auth' })]),
      ])]),
    ] },
    bucket: { getFiles: async () => [[{ name: 'image.jpg', metadata }], null] },
    key: hmacKey, projectId: 'test-project', bucketName: 'test-bucket',
    maxAuthUsers: 10, maxAuthListPages: 10, maxDocuments: 10, maxObjects: 10,
  });
  assert.equal(compareManifests(baseline, result.manifest).equal, true);
  assert.deepEqual(result.diagnostics, { unsafeIntegers: 1 });
  assert.deepEqual(result.manifest.links.unresolvedUserRefs, [{
    document: fingerprint(hmacKey, 'document', 'old/missing/children/child'),
    field: 'sendByID', uid: fingerprint(hmacKey, 'uid', 'missing-auth'),
  }]);
  assert.match(result.archiveSha256, /^[a-f0-9]{64}$/);
  assert.equal(JSON.stringify(result.manifest).includes('PRIVATE'), false);
});

test('malformed typed values stop manifest creation instead of inventing content', () => {
  for (const value of [{ unsupportedValue: 1 }, { booleanValue: 'false' },
    { integerValue: '9223372036854775808' }, { timestampValue: 'bad' },
    { bytesValue: 'not-base64' }, { referenceValue: 'users/u1' },
    { stringValue: 'value', nullValue: null }]) {
    assert.throws(() => decodeArchiveFields({ value }));
  }
});

test('an incomplete archive is rejected by the authenticated reader', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-incomplete-manifest-'));
  const archiveKey = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(join(directory, 'partial.clrsenc'), archiveKey);
  await writer.writeJson({ kind: 'source', format: 2, project: 'test-project',
    database: '(default)', bucket: 'test-bucket', scope: 'metadata',
    completeSource: false, storagePrefix: '', passwordHashesIncluded: false });
  await writer.finish({});
  await assert.rejects(collectArchiveManifest({ archivePath: join(directory, 'partial.clrsenc'),
    archiveKey, hmacKey: randomBytes(32) }));
});
