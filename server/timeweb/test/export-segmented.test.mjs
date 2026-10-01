import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { appendFile, mkdtemp, readFile, readdir, stat, unlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter, readEncryptedArchive } from '../encrypted-archive.mjs';
import { exportFirebase } from '../export-core.mjs';
import { exportSegmentedFirebase, classifyExportFailure } from '../export-segmented-core.mjs';
import { scanImportArchive } from '../import-core.mjs';
import { collectArchiveManifest } from '../manifest-from-archive.mjs';
import { verifyExportManifest } from '../verify-export-manifest.mjs';
import { parseSegmentedArgs } from '../export-firebase-segmented.mjs';

const source = { project: 'test-project', database: '(default)', bucket: 'test-bucket' };
const limits = { maxAuthUsers: 10, maxAuthListPages: 10, maxFirestoreCollections: 30,
  maxFirestoreReferences: 30, maxFirestoreListPages: 100, maxFirestoreConcurrency: 8,
  maxStorageObjects: 10, maxStorageListPages: 20, maxStorageBytes: 10000, maxObjectBytes: 1000 };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function fixture(count = 8) {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-segmented-'));
  const key = randomBytes(32);
  const metadataArchive = join(dir, 'metadata-source.clrsenc');
  const writer = await EncryptedArchiveWriter.create(metadataArchive, key);
  await exportFirebase({ auth: { async listUsers() { return { users: [{ uid: 'u1' }] }; } },
    firestoreApi: {
      async listCollectionIds(path) { return { collectionIds: path === '' ? ['users'] : [] }; },
      async listDocuments() { return { documents: [{
        name: 'projects/test-project/databases/(default)/documents/users/u1',
        fields: { name: { stringValue: 'fixture name' } },
        createTime: '2026-09-30T00:00:00Z', updateTime: '2026-09-30T00:00:00Z',
      }] }; },
    }, writer, project: source.project, bucketName: source.bucket, scope: 'metadata', limits });
  const items = Array.from({ length: count }, (_, index) => {
    const bytes = Buffer.from(`fixture image ${index}`);
    return { name: `fixture/${index}.jpg`, bytes, metadata: { size: String(bytes.length),
      generation: '1', metageneration: '1', contentType: 'image/jpeg',
      md5Hash: createHash('md5').update(bytes).digest('base64') } };
  });
  const tracking = { active: 0, peak: 0, downloads: 0, listing: 0, failOnce: false, mutateFinal: false };
  const bucket = {
    async getFiles() {
      tracking.listing++;
      const files = items.map(({ name, metadata }) => ({ name, metadata: { ...metadata } }));
      if (tracking.mutateFinal && tracking.listing % 2 === 0) files[0].metadata.generation = '2';
      return [files, null];
    },
    file(name, options) {
      const item = items.find((entry) => entry.name === name);
      assert.equal(options.generation, item.metadata.generation);
      return { async *createReadStream() {
        tracking.active++; tracking.downloads++; tracking.peak = Math.max(tracking.peak, tracking.active);
        try {
          yield item.bytes.subarray(0, 5);
          if (tracking.failOnce && name === items[0].name) {
            tracking.failOnce = false; await sleep(15); throw new Error('synthetic interruption');
          }
          await sleep(5); yield item.bytes.subarray(5);
        } finally { tracking.active--; }
      } };
    },
  };
  return { dir, key, metadataArchive, bucket, tracking, items,
    outputPath: join(dir, 'bundle', 'full.clrsenc') };
}

async function run(f, options = {}) {
  return exportSegmentedFirebase({ ...f, source, limits, ...options });
}

test('sealed segmented export keeps prefetch <=4 and gives identical stable reader/import/HMAC proof', async () => {
  const f = await fixture();
  const summary = await run(f);
  assert.equal(f.tracking.peak, 4); assert.equal(f.tracking.active, 0);
  assert.equal(summary.authUsers, 1); assert.equal(summary.firestoreDocuments, 1);
  assert.equal(summary.storageObjects, 8);
  assert.equal((await stat(f.outputPath)).mode & 0o077, 0);
  assert.equal((await stat(join(f.dir, 'bundle'))).mode & 0o077, 0);
  const first = await scanImportArchive({ archivePath: f.outputPath, key: f.key, limits });
  const second = await scanImportArchive({ archivePath: f.outputPath, key: f.key, limits });
  assert.equal(first.archiveSha256, second.archiveSha256);
  assert.equal(first.source.finalSyncRequired, true);
  assert.equal(first.source.snapshotConsistent, false);
  const hmacKey = randomBytes(32);
  const collected = await collectArchiveManifest({ archivePath: f.outputPath, archiveKey: f.key,
    hmacKey, limits: { ...limits, maxFirestoreDocuments: 30 } });
  const verified = await verifyExportManifest({ archivePath: f.outputPath, archiveKey: f.key,
    hmacKey, manifest: collected.manifest });
  assert.equal(verified.equalToInventory, true);
  assert.equal(verified.archiveSha256, first.archiveSha256);
  const before = f.tracking.listing;
  await assert.rejects(run(f), /Completed bundle index already exists/);
  assert.equal(f.tracking.listing, before);
});

test('interrupted jobs retain ciphertext and retry reuses only individually verified complete shards', async () => {
  const f = await fixture(); f.tracking.failOnce = true;
  await assert.rejects(run(f), /synthetic interruption/);
  assert.equal(f.tracking.active, 0);
  const names = await readdir(join(f.dir, 'bundle'));
  const complete = names.filter((name) => /^storage-[a-f0-9]{64}\.clrsenc$/.test(name));
  assert.ok(complete.length > 0);
  assert.ok(names.some((name) => name.includes('.incomplete-')));
  assert.ok(!names.includes('full.clrsenc'));
  const previous = f.tracking.downloads;
  let cap;
  await run(f, { beforeStorageStart: async (remainingCap) => { cap = remainingCap; } });
  assert.equal(f.tracking.downloads - previous, f.items.length - complete.length);
  const cachedBytes = complete.length * f.items[0].bytes.length;
  assert.equal(cap, limits.maxStorageBytes - cachedBytes);
  const scanned = await scanImportArchive({ archivePath: f.outputPath, key: f.key, limits });
  assert.equal(scanned.counts.storageObjects, f.items.length);
});

test('corrupted and missing sealed shards never produce a complete reader result', async () => {
  for (const damage of ['corrupt', 'missing', 'trailing']) {
    const f = await fixture(2); await run(f);
    const names = await readdir(join(f.dir, 'bundle'));
    const path = join(f.dir, 'bundle', names.find((name) => name.startsWith('storage-')));
    if (damage === 'missing') await unlink(path);
    else if (damage === 'trailing') await appendFile(path, Buffer.from('trailing'));
    else { const bytes = await readFile(path); bytes[30] ^= 1; await import('node:fs/promises')
      .then(({ writeFile }) => writeFile(path, bytes)); }
    let ended = false;
    await assert.rejects(async () => {
      for await (const frame of readEncryptedArchive(f.outputPath, f.key)) {
        if (frame.type === 'json' && frame.record?.kind === 'end') ended = true;
      }
    });
    assert.equal(ended, false);
  }
});

test('source generation or metadata mutation prevents publication and retry never reuses old metadata', async () => {
  const f = await fixture(2); f.tracking.mutateFinal = true;
  await assert.rejects(run(f), /Storage inventory changed/);
  assert.ok(!(await readdir(join(f.dir, 'bundle'))).includes('full.clrsenc'));
  const previous = f.tracking.downloads;
  f.tracking.mutateFinal = false; f.items[0].metadata.generation = '2';
  f.items[0].metadata.metageneration = '2';
  await run(f);
  assert.equal(f.tracking.downloads - previous, 1);
  assert.equal((await scanImportArchive({ archivePath: f.outputPath, key: f.key, limits }))
    .counts.storageObjects, 2);
});

test('safe diagnostics classify disk, access and generation errors without forwarding private values', () => {
  assert.equal(classifyExportFailure(new Error('Insufficient free disk for bounded Storage export')), 'disk_reserve');
  assert.equal(classifyExportFailure({ code: 404, message: 'private name' }), 'source_mutated');
  assert.equal(classifyExportFailure({ code: 403, message: 'private name' }), 'source_access');
  assert.equal(classifyExportFailure({ code: 'CONTENT_DOWNLOAD_MISMATCH', message: 'private name' }), 'source_checksum');
  assert.equal(classifyExportFailure(new Error('private name')), 'source_or_archive_error');
});

test('segmented CLI preserves explicit source/read caps and accepts prefetch only 1..4', () => {
  const args = ['--project', source.project, '--bucket', source.bucket,
    '--out', '/private/bundle/full.clrsenc', '--key-file', '/private/key',
    '--metadata-archive', '/private/metadata.clrsenc', '--max-auth-users', '10',
    '--max-auth-list-pages', '10', '--max-firestore-collections', '30',
    '--max-firestore-references', '30', '--max-firestore-list-pages', '100',
    '--max-storage-objects', '10', '--max-storage-list-pages', '20',
    '--max-storage-bytes', '10000', '--confirm-project', source.project,
    '--confirm-bucket', source.bucket, '--confirm-read-cost'];
  assert.equal(parseSegmentedArgs(args).maxPrefetch, 4);
  assert.equal(parseSegmentedArgs([...args, '--max-storage-prefetch', '1']).maxPrefetch, 1);
  for (const invalid of ['0', '5', '1.5', '04']) {
    assert.throws(() => parseSegmentedArgs([...args, '--max-storage-prefetch', invalid]));
  }
  assert.throws(() => parseSegmentedArgs([...args, '--scope', 'metadata']));
});
