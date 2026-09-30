import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { fingerprint } from '../manifest.mjs';
import { verifyExportManifest } from '../verify-export-manifest.mjs';

const source = { kind: 'source', format: 2, project: 'demo-project',
  database: '(default)', bucket: 'demo-bucket', scope: 'all',
  storagePrefix: '', completeSource: true, passwordHashesIncluded: false };
const name = 'photos/synthetic.jpg';
const payload = Buffer.from('synthetic private image');

function fixtureManifest(key) {
  return {
    schemaVersion: 2,
    hmacKeyId: fingerprint(key, 'manifest-key', 'CLRS manifest v2'),
    source: { project: fingerprint(key, 'project', source.project),
      bucket: fingerprint(key, 'bucket', source.bucket) },
    auth: { count: 1, users: [{ uid: fingerprint(key, 'uid', 'u1'),
      email: null, disabled: false, emailVerified: false, providers: [],
      claims: fingerprint(key, 'claims', '{}') }] },
    firestore: { count: 1, countsByCollection: { users: 1 },
      documents: [{ path: fingerprint(key, 'document', 'users/u1'),
        collection: 'users', content: fingerprint(key, 'document-content', '{}') }] },
    storage: { count: 1, bytes: payload.length, objects: [{
      key: fingerprint(key, 'object', name), bytes: payload.length,
      checksum: null,
    }] },
    links: { authWithoutProfile: [], profileWithoutAuth: [],
      unresolvedUserRefs: [], missingStorageObjects: [] },
  };
}

async function fixtureArchive(archiveKey, { sourceOverride, badSha = false } = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-verify-manifest-'));
  const archivePath = join(dir, 'source.clrsenc');
  const writer = await EncryptedArchiveWriter.create(archivePath, archiveKey);
  await writer.writeJson({ ...source, ...sourceOverride });
  await writer.writeJson({ kind: 'auth-user', user: { uid: 'u1' } });
  await writer.writeJson({ kind: 'firestore-document', path: 'users/u1',
    fields: {}, createTime: '2026-09-30T00:00:00Z',
    updateTime: '2026-09-30T00:00:00Z' });
  await writer.writeJson({ kind: 'storage-object', name,
    metadata: { size: String(payload.length), generation: '1' } });
  await writer.writeBytes(payload);
  await writer.writeJson({ kind: 'storage-sha256', name,
    sha256: badSha ? '0'.repeat(64) : createHash('sha256').update(payload).digest('hex') });
  await writer.finish({ authUsers: 1, authListPages: 1,
    firestoreDocuments: 1, firestoreMissingParents: 0,
    firestoreReferences: 1, firestoreCollections: 1,
    firestoreListPages: 1, storageObjects: 1,
    storageBytes: payload.length, storageListPages: 1 });
  return archivePath;
}

test('encrypted full archive matches protected identity and Storage inventory', async () => {
  const archiveKey = randomBytes(32);
  const hmacKey = randomBytes(32);
  const result = await verifyExportManifest({
    archivePath: await fixtureArchive(archiveKey), archiveKey,
    manifest: fixtureManifest(hmacKey), hmacKey,
  });
  assert.equal(result.equalToInventory, true);
  assert.deepEqual(Object.values(result.comparison), Array(7).fill(0));
  assert.equal(result.counts.storageBytes, payload.length);
  assert.match(result.archiveSha256, /^[a-f0-9]{64}$/);
});

test('inventory drift is aggregate-only and a bad Storage hash is rejected', async () => {
  const archiveKey = randomBytes(32);
  const hmacKey = randomBytes(32);
  const manifest = fixtureManifest(hmacKey);
  manifest.storage.objects[0].bytes++;
  manifest.storage.bytes++;
  const result = await verifyExportManifest({
    archivePath: await fixtureArchive(archiveKey), archiveKey, manifest, hmacKey,
  });
  assert.equal(result.equalToInventory, false);
  assert.equal(result.comparison.storageMetadataChanged, 1);
  await assert.rejects(verifyExportManifest({
    archivePath: await fixtureArchive(archiveKey, { badSha: true }), archiveKey,
    manifest: fixtureManifest(hmacKey), hmacKey,
  }), /Storage checksum/);
});

test('source and HMAC key mismatches stop comparison', async () => {
  const archiveKey = randomBytes(32);
  const hmacKey = randomBytes(32);
  const manifest = fixtureManifest(hmacKey);
  await assert.rejects(verifyExportManifest({
    archivePath: await fixtureArchive(archiveKey), archiveKey,
    manifest, hmacKey: randomBytes(32),
  }), /HMAC key mismatch/);
  await assert.rejects(verifyExportManifest({
    archivePath: await fixtureArchive(archiveKey,
      { sourceOverride: { project: 'other-project' } }),
    archiveKey, manifest, hmacKey,
  }), /different Firebase sources/);
});
