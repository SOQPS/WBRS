import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { appendFile, chmod, mkdtemp, readFile, readdir, realpath, rm, stat,
  symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter, readPhysicalEncryptedArchive } from '../encrypted-archive.mjs';
import { exportFirebase } from '../export-core.mjs';
import { exportSegmentedFirebase } from '../export-segmented-core.mjs';
import { scanImportArchive } from '../import-core.mjs';
import { ensureStorageHeadroom } from '../export-firebase-encrypted.mjs';
import { seedSegmentedStorage, parseSeedArgs } from '../seed-segmented-storage.mjs';

const source = { project: 'fixture-project', database: '(default)', bucket: 'fixture-bucket' };
const limits = { maxAuthUsers: 10, maxAuthListPages: 10, maxFirestoreCollections: 30,
  maxFirestoreReferences: 30, maxFirestoreListPages: 100, maxFirestoreConcurrency: 8,
  maxStorageObjects: 10, maxStorageListPages: 20, maxStorageBytes: 10000, maxObjectBytes: 1000 };
const importLimits = { maxAuthUsers: 10, maxFirestoreDocuments: 30,
  maxStorageObjects: 10, maxStorageBytes: 10000, maxObjectBytes: 1000 };
async function metadata(path, key, name) {
  const writer = await EncryptedArchiveWriter.create(path, key);
  await exportFirebase({ auth: { async listUsers() { return { users: [{ uid: 'fixture1' }] }; } },
    firestoreApi: {
      async listCollectionIds(path) { return { collectionIds: path === '' ? ['users'] : [] }; },
      async listDocuments() { return { documents: [{
        name: `projects/${source.project}/databases/(default)/documents/users/fixture1`,
        fields: { name: { stringValue: name } },
        createTime: '2026-10-01T00:00:00Z', updateTime: '2026-10-01T00:00:00Z',
      }] }; },
    }, writer, project: source.project, bucketName: source.bucket, scope: 'metadata', limits });
}
function item(name, value) {
  const bytes = Buffer.from(value);
  return { name, bytes, metadata: { generation: '1', metageneration: '1',
    size: String(bytes.length), contentType: 'image/jpeg',
    md5Hash: createHash('md5').update(bytes).digest('base64') } };
}
async function fixture(t) {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'clrs-offline-seed-')));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const key = randomBytes(32);
  const metadataArchive = join(dir, 'old-metadata.clrsenc');
  await metadata(metadataArchive, key, 'old fixture');
  const items = [item('fixture/0', 'first fixture'), item('fixture/1', 'second fixture'),
    item('fixture/2', 'third fixture')];
  let downloads = 0;
  const bucket = {
    async getFiles() { return [items.map(({ name, metadata }) => ({ name, metadata: { ...metadata } })), null]; },
    file(name, options) {
      const found = items.find((entry) => entry.name === name);
      assert.equal(options.generation, found.metadata.generation);
      return { async *createReadStream() { downloads++; yield found.bytes; } };
    },
  };
  const archivePath = join(dir, 'original', 'full.clrsenc');
  await exportSegmentedFirebase({ metadataArchive, key, bucket, source, limits, outputPath: archivePath });
  const proof = await scanImportArchive({ archivePath, key, limits: importLimits });
  return { dir, key, metadataArchive, archivePath, bucket, items,
    expectedArchiveSha256: proof.archiveSha256, expectedSource: source,
    outputDirectory: join(dir, 'new-bundle'), downloads: () => downloads };
}
const seed = (f, options = {}) => seedSegmentedStorage({ ...f, limits: importLimits, ...options });
async function replaceIndex(f, mutate) {
  const frames = [];
  for await (const frame of readPhysicalEncryptedArchive(f.archivePath, f.key)) frames.push(frame.record);
  mutate(frames[0]);
  await unlink(f.archivePath);
  const writer = await EncryptedArchiveWriter.create(f.archivePath, f.key);
  await writer.writeJson(frames[0]); await writer.finish({ indexShards: frames[0].shards.length });
}

test('offline seed hardlinks verified Storage only; fresh metadata and changed/add/delete inventory produce independent FULL', async (t) => {
  const f = await fixture(t);
  const originalIndex = await readFile(f.archivePath);
  const originalMetadata = await readFile(join(dirname(f.archivePath), 'metadata.clrsenc'));
  const result = await seed(f);
  assert.equal(result.originalSnapshotUnchanged, true);
  assert.equal(result.networkCalls, 0); assert.equal(result.linkedObjects, 3);
  const files = await readdir(f.outputDirectory);
  assert.equal(files.length, 3);
  assert.equal(files.some((file) => file === 'metadata.clrsenc' || file === 'full.clrsenc'), false);
  for (const file of files) {
    const original = await stat(join(dirname(f.archivePath), file));
    const reused = await stat(join(f.outputDirectory, file));
    assert.equal(reused.ino, original.ino); assert.equal(reused.dev, original.dev);
  }
  const downloads = f.downloads();
  f.items[0].metadata.generation = '2'; f.items[0].metadata.metageneration = '2';
  f.items.splice(2, 1); f.items.push(item('fixture/new', 'new fixture'));
  const freshMetadata = join(f.dir, 'fresh-metadata.clrsenc');
  await metadata(freshMetadata, f.key, 'fresh fixture');
  const freshPath = join(f.outputDirectory, 'full.clrsenc');
  let reused;
  await exportSegmentedFirebase({ metadataArchive: freshMetadata, key: f.key,
    bucket: f.bucket, source, limits, outputPath: freshPath,
    onProgress: async (state) => { reused = state.reused; } });
  assert.equal(f.downloads() - downloads, 2); assert.equal(reused, 1);
  const fresh = await scanImportArchive({ archivePath: freshPath, key: f.key, limits: importLimits });
  assert.equal(fresh.counts.storageObjects, 3);
  assert.notEqual(fresh.archiveSha256, f.expectedArchiveSha256);
  assert.equal((await scanImportArchive({ archivePath: f.archivePath, key: f.key,
    limits: importLimits })).archiveSha256, f.expectedArchiveSha256);
  assert.deepEqual(await readFile(f.archivePath), originalIndex);
  assert.deepEqual(await readFile(join(dirname(f.archivePath), 'metadata.clrsenc')), originalMetadata);
});

test('corrupt/missing/trailing old shard fails complete proof before destination creation', async (t) => {
  for (const damage of ['corrupt', 'missing', 'trailing']) {
    const f = await fixture(t);
    const name = (await readdir(dirname(f.archivePath))).find((file) => file.startsWith('storage-'));
    const path = join(dirname(f.archivePath), name);
    if (damage === 'missing') await unlink(path);
    else if (damage === 'trailing') await appendFile(path, Buffer.from('trailing fixture'));
    else { const bytes = await readFile(path); bytes[30] ^= 1; await writeFile(path, bytes); }
    await assert.rejects(seed(f));
    await assert.rejects(stat(f.outputDirectory), { code: 'ENOENT' });
  }
});

test('authenticated malicious index traversal or changed object identity cannot seed', async (t) => {
  for (const field of ['file', 'objectIdentity']) {
    const f = await fixture(t);
    await replaceIndex(f, (index) => { index.shards[1][field] = field === 'file'
      ? '../outside.clrsenc' : 'a'.repeat(64); });
    await assert.rejects(seed(f));
    await assert.rejects(stat(f.outputDirectory), { code: 'ENOENT' });
  }
});

test('symlink source/shard/destination-parent and existing destination are rejected', async (t) => {
  const f = await fixture(t);
  const alias = join(f.dir, 'alias.clrsenc'); await symlink(f.archivePath, alias);
  await assert.rejects(seed(f, { archivePath: alias }), /non-symlink/);
  const parentAlias = join(f.dir, 'parent-link'); await symlink(f.dir, parentAlias);
  await assert.rejects(seed(f, { outputDirectory: join(parentAlias, 'new') }), /non-symlink/);
  await assert.rejects(seed(f, { outputDirectory: dirname(f.archivePath) }), /Separate/);
  await seed(f);
  await assert.rejects(seed(f), /already exists/);
  const g = await fixture(t);
  const name = (await readdir(dirname(g.archivePath))).find((file) => file.startsWith('storage-'));
  const path = join(dirname(g.archivePath), name);
  const saved = join(g.dir, 'saved-shard.clrsenc');
  await writeFile(saved, await readFile(path), { mode: 0o600 });
  await unlink(path); await symlink(saved, path);
  await assert.rejects(seed(g));
});

test('private ownership/mode, pinned source/SHA/key and reviewed upper bounds remain mandatory', async (t) => {
  const f = await fixture(t);
  await assert.rejects(seed(f, { expectedArchiveSha256: 'a'.repeat(64) }), /snapshot mismatch/);
  await assert.rejects(seed(f, { expectedSource: { ...source, bucket: 'other' } }), /snapshot mismatch/);
  await assert.rejects(seed(f, { key: randomBytes(32) }));
  await assert.rejects(seed(f, { limits: { maxStorageBytes: 7200000001 } }), /only decrease/);
  await chmod(dirname(f.archivePath), 0o750);
  await assert.rejects(seed(f), /private|Private/);
});

test('2GiB reserve applies before directory creation and every hardlink; interrupted cache remains unsealed', async (t) => {
  const f = await fixture(t);
  const lowDisk = async (path, bytes) => ensureStorageHeadroom(path, bytes, {
    statfsImpl: async () => ({ bavail: 2n * 1024n ** 3n - 1n, bsize: 1n }),
  });
  await assert.rejects(seed(f, { headroom: lowDisk }), /Insufficient/);
  await assert.rejects(stat(f.outputDirectory), { code: 'ENOENT' });
  let calls = 0;
  await assert.rejects(seed(f, { headroom: async (path, bytes) => {
    assert.equal(bytes, 0);
    if (++calls >= 3) return lowDisk(path, bytes);
  } }), /Insufficient/);
  assert.equal((await readdir(f.outputDirectory)).length, 1);
  assert.equal((await scanImportArchive({ archivePath: f.archivePath, key: f.key,
    limits: importLimits })).archiveSha256, f.expectedArchiveSha256);
  await assert.rejects(scanImportArchive({ archivePath: join(f.outputDirectory, 'full.clrsenc'),
    key: f.key, limits: importLimits }), { code: 'ENOENT' });
});

test('source mutation during linking is detected before a successful seed result', async (t) => {
  const f = await fixture(t);
  let changed = false;
  await assert.rejects(seed(f, { beforeLink: async () => {
    if (changed) return; changed = true;
    await appendFile(f.archivePath, Buffer.from('synthetic source mutation'));
  } }));
  assert.equal((await readdir(f.outputDirectory)).some((file) => file === 'full.clrsenc'), false);
});

test('offline CLI requires exact reviewed arguments and rejects unknown/duplicate options', () => {
  const args = ['--archive', '/private/old/full.clrsenc', '--key-file', '/private/key',
    '--out-dir', '/private/new', '--project', source.project, '--database', source.database,
    '--bucket', source.bucket, '--confirm-archive-sha256', 'a'.repeat(64)];
  assert.equal(parseSeedArgs(args).get('--out-dir'), '/private/new');
  assert.throws(() => parseSeedArgs(args.slice(0, -2)));
  assert.throws(() => parseSeedArgs([...args, '--out-dir', '/other']));
  assert.throws(() => parseSeedArgs([...args, '--confirm-read-cost', 'true']));
});
