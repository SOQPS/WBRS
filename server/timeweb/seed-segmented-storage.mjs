#!/usr/bin/env node
// Offline reuse only: never contacts Firebase, MySQL, Timeweb or S3.
import { link, lstat, mkdir, open, readFile, realpath } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { readPhysicalEncryptedArchive } from './encrypted-archive.mjs';
import { inspectSealedShard } from './export-segmented-core.mjs';
import { ensureStorageHeadroom } from './export-firebase-encrypted.mjs';
import { scanImportArchive } from './import-core.mjs';
import { storageShardIdentity } from './sealed-archive-reader.mjs';

export const SEED_LIMITS = Object.freeze({ maxAuthUsers: 10000,
  maxFirestoreDocuments: 150000, maxStorageObjects: 10000,
  maxStorageBytes: 7200000000, maxObjectBytes: 64000000 });
const ownUid = process.getuid();
const sha = (value) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const inside = (parent, child) => {
  const path = relative(parent, child);
  return path === '' || (path !== '..' && !path.startsWith(`..${sep}`) && !isAbsolute(path));
};
async function privatePath(path, directory = false) {
  if (!isAbsolute(path) || resolve(path) !== path || path.includes('.partial')) {
    throw new Error('Canonical absolute completed private path required');
  }
  const info = await lstat(path);
  if ((directory ? !info.isDirectory() : !info.isFile()) || info.uid !== ownUid
      || (info.mode & 0o077) !== 0 || await realpath(path) !== path) {
    throw new Error('Private owned non-symlink path required');
  }
  return info;
}
async function readIndex(path, key) {
  const digest = createHash('sha256');
  const records = [];
  for await (const frame of readPhysicalEncryptedArchive(path, key, {
    onCiphertext: (bytes) => digest.update(bytes),
  })) {
    if (frame.type !== 'json' || records.length >= 2) throw new Error('Invalid sealed index');
    records.push(frame.record);
  }
  const [index, end] = records;
  if (index?.kind !== 'archive-bundle' || !Array.isArray(index.shards)
      || index.shards.length < 1 || index.shards.length > 10001
      || end?.kind !== 'end' || end.summary?.indexShards !== index.shards.length) {
    throw new Error('Complete segmented index required');
  }
  return { index, indexSha256: digest.digest('hex') };
}

export async function seedSegmentedStorage({ archivePath, key, outputDirectory,
    expectedSource, expectedArchiveSha256, limits = {},
    beforeLink = async () => {}, // dependency hook for deterministic fault tests
    headroom = ensureStorageHeadroom, onProgress = async () => {} }) {
  if (!Buffer.isBuffer(key) || key.length !== 32 || !sha(expectedArchiveSha256)
      || ['project', 'database', 'bucket'].some((name) => typeof expectedSource?.[name] !== 'string'
        || !expectedSource[name])) throw new Error('Reviewed source/key/composite SHA required');
  const cap = { ...SEED_LIMITS, ...limits };
  if (Object.keys(cap).some((name) => !Number.isSafeInteger(cap[name]) || cap[name] < 1
      || !(name in SEED_LIMITS) || cap[name] > SEED_LIMITS[name])) {
    throw new Error('Seed limits may only decrease');
  }
  await privatePath(archivePath);
  const sourceDirectory = dirname(archivePath);
  const sourceInfo = await privatePath(sourceDirectory, true);
  if (!isAbsolute(outputDirectory) || resolve(outputDirectory) !== outputDirectory
      || inside(sourceDirectory, outputDirectory) || inside(outputDirectory, sourceDirectory)) {
    throw new Error('Separate canonical bundle directory required');
  }
  const parentInfo = await privatePath(dirname(outputDirectory), true);
  if (parentInfo.dev !== sourceInfo.dev) throw new Error('Hardlink reuse requires the same filesystem');
  try { await lstat(outputDirectory); throw new Error('Seed destination already exists'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  await headroom(dirname(outputDirectory), 0);
  const { index, indexSha256 } = await readIndex(archivePath, key);
  const sizes = new Map();
  // This complete read verifies GCM/end/EOF, every ciphertext/plaintext SHA,
  // source identity, counts and unique records before any destination exists.
  // The scanner holds at most one maxObjectBytes buffer; no plaintext is saved.
  const before = await scanImportArchive({ archivePath, key, limits: cap,
    onObject: ({ source, name, metadata, size }) => {
      sizes.set(storageShardIdentity(key, source, name, metadata), size);
    } });
  if (before.archiveSha256 !== expectedArchiveSha256
      || ['project', 'database', 'bucket'].some((name) => before.source[name] !== expectedSource[name])
      || before.source.segmented !== true || sizes.size !== before.counts.storageObjects) {
    throw new Error('Reviewed source snapshot mismatch');
  }
  // The FULL reader has now validated every descriptor filename and identity.
  for (const shard of index.shards) await privatePath(join(sourceDirectory, shard.file));
  await mkdir(outputDirectory, { mode: 0o700 });
  await privatePath(outputDirectory, true);
  let linkedObjects = 0;
  let linkedSourceBytes = 0;
  for (const shard of index.shards.slice(1)) {
    const sourcePath = join(sourceDirectory, shard.file);
    const original = await privatePath(sourcePath);
    const size = sizes.get(shard.objectIdentity);
    if (!Number.isSafeInteger(size)) throw new Error('Shard inventory identity mismatch');
    const verified = await inspectSealedShard(sourcePath, key, { scope: 'storage',
      source: expectedSource, identity: shard.objectIdentity, expectedSize: size });
    if (verified.ciphertextBytes !== shard.ciphertextBytes
        || verified.ciphertextSha256 !== shard.ciphertextSha256) {
      throw new Error('Shard differs from authenticated index');
    }
    await headroom(outputDirectory, 0);
    await beforeLink();
    if ((await privatePath(outputDirectory, true)).dev !== original.dev) {
      throw new Error('Seed directory filesystem changed');
    }
    const targetPath = join(outputDirectory, shard.file);
    await link(sourcePath, targetPath); // no fallback copy, overwrite, chmod or truncate
    const linked = await privatePath(targetPath);
    const afterLink = await privatePath(sourcePath);
    if (linked.dev !== original.dev || linked.ino !== original.ino
        || linked.size !== original.size || afterLink.ino !== original.ino
        || afterLink.size !== original.size) throw new Error('Source changed during hardlink reuse');
    linkedObjects++; linkedSourceBytes += size;
    await onProgress({ linkedObjects, linkedSourceBytes });
  }
  const directory = await open(outputDirectory, 'r');
  try { await directory.sync(); } finally { await directory.close(); }
  const after = await scanImportArchive({ archivePath, key, limits: cap });
  if (after.archiveSha256 !== before.archiveSha256
      || (await readIndex(archivePath, key)).indexSha256 !== indexSha256) {
    throw new Error('Original snapshot changed during seed');
  }
  await headroom(outputDirectory, 0);
  return { status: 'offline_storage_seed_verified', originalArchiveSha256: before.archiveSha256,
    originalSnapshotUnchanged: true, linkedObjects, linkedSourceBytes,
    fullIndexCreated: false, metadataReused: false, networkCalls: 0, finalSyncRequired: true };
}

export function parseSeedArgs(args) {
  const required = ['--archive', '--key-file', '--out-dir', '--project', '--database',
    '--bucket', '--confirm-archive-sha256'];
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    if (!required.includes(args[index]) || !args[index + 1] || values.has(args[index])) {
      throw new Error('Invalid offline seed arguments');
    }
    values.set(args[index], args[index + 1]);
  }
  if (required.some((name) => !values.has(name))) throw new Error('Explicit offline source arguments required');
  return values;
}
async function main() {
  const values = parseSeedArgs(process.argv.slice(2));
  const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const keyPath = values.get('--key-file');
  await privatePath(keyPath);
  if ([keyPath, values.get('--archive'), values.get('--out-dir')].some((path) => inside(repository, path))
      || keyPath === values.get('--archive') || inside(values.get('--out-dir'), keyPath)) {
    throw new Error('Source, key and new bundle must remain separate outside Git');
  }
  const key = await readFile(keyPath);
  try {
    let last = 0;
    const result = await seedSegmentedStorage({ archivePath: values.get('--archive'), key,
      outputDirectory: values.get('--out-dir'), expectedArchiveSha256: values.get('--confirm-archive-sha256'),
      expectedSource: { project: values.get('--project'), database: values.get('--database'), bucket: values.get('--bucket') },
      onProgress: async (counts) => {
        if (counts.linkedObjects === 1 || counts.linkedObjects % 100 === 0 || Date.now() - last >= 30000) {
          last = Date.now(); process.stdout.write(`${JSON.stringify({ status: 'offline_storage_seed_progress', ...counts })}\n`);
        }
      } });
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } finally { key.fill(0); }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => {
    process.stderr.write('Offline seed failed. Preserve the original snapshot and any unsealed cache; no source or target network operation was performed.\n');
    process.exitCode = 1;
  });
}
