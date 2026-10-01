import { createHash, randomBytes } from 'node:crypto';
import { link, lstat, mkdir, rename } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { EncryptedArchiveWriter, readPhysicalEncryptedArchive } from './encrypted-archive.mjs';
import { exportFirebase } from './export-core.mjs';
import { storageShardIdentity } from './sealed-archive-reader.mjs';

const integer = (value) => Number.isSafeInteger(value) && value >= 0;
const summaryNames = ['authUsers', 'authListPages', 'firestoreDocuments',
  'firestoreMissingParents', 'firestoreReferences', 'firestoreCollections',
  'firestoreListPages', 'storageObjects', 'storageBytes', 'storageListPages'];

export function classifyExportFailure(error) {
  if (error?.message === 'Insufficient free disk for bounded Storage export') return 'disk_reserve';
  if ([401, 403].includes(Number(error?.code))) return 'source_access';
  if ([404, 412].includes(Number(error?.code))) return 'source_mutated';
  if (error?.code === 'ENOSPC') return 'disk_full';
  if (error?.code === 'CONTENT_DOWNLOAD_MISMATCH'
      || ['Storage checksum or size mismatch', 'Storage shard checksum mismatch']
        .includes(error?.message)) return 'source_checksum';
  if (error?.message === 'Storage read timed out') return 'source_timeout';
  if (error?.message === 'Storage inventory changed during export') return 'source_mutated';
  return 'source_or_archive_error';
}

export async function inspectSealedShard(path, key, { scope, source, identity,
    expectedSize, maxAuthUsers = 10000, maxFirestoreDocuments = 150000 }) {
  const file = await lstat(path);
  if (!file.isFile() || (file.mode & 0o077) !== 0) throw new Error('Unsafe shard file');
  const ciphertext = createHash('sha256');
  let first = true;
  let summary;
  let authCount = 0;
  let documentCount = 0;
  let storageCount = 0;
  let pending;
  let objectIdentity;
  let sourceRecord;
  const seenAuth = new Set();
  const seenDocuments = new Set();
  for await (const frame of readPhysicalEncryptedArchive(path, key, {
    onCiphertext: (bytes) => ciphertext.update(bytes),
  })) {
    if (first) {
      first = false; sourceRecord = frame.record;
      if (frame.type !== 'json' || sourceRecord?.kind !== 'source'
          || sourceRecord.format !== 2 || sourceRecord.scope !== scope
          || sourceRecord.storagePrefix !== '' || sourceRecord.completeSource !== false
          || sourceRecord.passwordHashesIncluded !== false
          || sourceRecord.project !== source.project || sourceRecord.bucket !== source.bucket
          || sourceRecord.database !== source.database) throw new Error('Shard source mismatch');
      continue;
    }
    if (frame.type === 'bytes') {
      if (!pending || frame.bytes.length > pending.size - pending.received) {
        throw new Error('Invalid shard byte section');
      }
      pending.received += frame.bytes.length;
      pending.hash.update(frame.bytes); pending.md5?.update(frame.bytes); continue;
    }
    const row = frame.record;
    if (row?.kind === 'end') {
      if (pending || summary) throw new Error('Invalid shard end');
      summary = row.summary; continue;
    }
    if (summary) throw new Error('Shard has trailing records');
    if (scope === 'metadata') {
      if (row?.kind === 'auth-user') {
        if (!row.user?.uid || seenAuth.has(row.user.uid)
            || 'passwordHash' in row.user || 'passwordSalt' in row.user
            || ++authCount > maxAuthUsers) throw new Error('Invalid metadata Auth section');
        seenAuth.add(row.user.uid);
      } else if (row?.kind === 'firestore-document') {
        if (!row.path || !row.fields || seenDocuments.has(row.path)
            || ++documentCount > maxFirestoreDocuments) throw new Error('Invalid metadata document section');
        seenDocuments.add(row.path);
      } else throw new Error('Unexpected metadata shard record');
    } else if (row?.kind === 'storage-object' && !pending && storageCount === 0) {
      const size = Number(row.metadata?.size);
      objectIdentity = storageShardIdentity(key, source, row.name, row.metadata);
      if (!integer(size) || size !== expectedSize || objectIdentity !== identity) {
        throw new Error('Storage shard identity mismatch');
      }
      pending = { size, received: 0, name: row.name, hash: createHash('sha256'),
        md5: row.metadata.md5Hash ? createHash('md5') : null, md5Hash: row.metadata.md5Hash };
    } else if (row?.kind === 'storage-sha256' && pending) {
      if (row.name !== pending.name || pending.received !== pending.size
          || pending.hash.digest('hex') !== row.sha256
          || (pending.md5 && pending.md5.digest('base64') !== pending.md5Hash)) {
        throw new Error('Storage shard checksum mismatch');
      }
      storageCount++; pending = null;
    } else throw new Error('Unexpected Storage shard record');
  }
  if (!summary || summaryNames.some((name) => !integer(summary[name]))
      || summary.authUsers !== authCount || summary.firestoreDocuments !== documentCount
      || summary.storageObjects !== storageCount
      || summary.firestoreDocuments + summary.firestoreMissingParents !== summary.firestoreReferences
      || (scope === 'metadata' ? storageCount !== 0 || summary.storageBytes !== 0
        : storageCount !== 1 || summary.storageBytes !== expectedSize)) {
    throw new Error('Shard completion counts mismatch');
  }
  return { file: basename(path), scope, ciphertextBytes: file.size,
    ciphertextSha256: ciphertext.digest('hex'), ...(identity ? { objectIdentity: identity } : {}),
    summary, sourceRecord };
}

async function inventory(bucket, source, key, limits, counters) {
  const result = [];
  const seen = new Set();
  const tokens = new Set();
  let query = { autoPaginate: false, maxResults: 100, prefix: '' };
  let bytes = 0;
  while (query) {
    if (++counters.pages > limits.maxStorageListPages) throw new Error('Storage list-page limit reached');
    const [files, following] = await bucket.getFiles(query);
    if (!Array.isArray(files)) throw new Error('Invalid Storage inventory');
    for (const file of files) {
      const size = Number(file.metadata?.size);
      if (!file.name || typeof file.name !== 'string' || seen.has(file.name)
          || !file.metadata?.generation || !integer(size) || size > limits.maxObjectBytes
          || result.length >= limits.maxStorageObjects || size > limits.maxStorageBytes - bytes) {
        throw new Error('Storage inventory limit or identity violation');
      }
      seen.add(file.name); bytes += size;
      result.push({ name: file.name, metadata: file.metadata, size,
        identity: storageShardIdentity(key, source, file.name, file.metadata) });
    }
    if (following) {
      if (typeof following.pageToken !== 'string' || !following.pageToken
          || tokens.has(following.pageToken)) throw new Error('Invalid Storage pagination');
      tokens.add(following.pageToken);
      query = { ...following, autoPaginate: false, maxResults: 100, prefix: '' };
    } else query = null;
  }
  return { objects: result, bytes };
}

async function retainedWriter(path, key, onPreserved) {
  const writer = await EncryptedArchiveWriter.create(path, key);
  const abort = writer.abort.bind(writer);
  let preserved = false;
  writer.abort = async () => {
    if (!writer.closed && !preserved) {
      const retained = path + `.incomplete-${randomBytes(8).toString('hex')}`;
      await writer.file.sync();
      await link(writer.partialPath, retained); preserved = true;
      onPreserved?.();
    }
    await abort();
  };
  return writer;
}

// Download jobs are bounded, independently sealed, and durable. Writing each
// shard uses a fresh random GCM header; no nonce/counter chain is ever resumed.
export async function exportSegmentedFirebase({ metadataArchive, outputPath, key,
    bucket, source, limits, maxPrefetch = 4, beforeStorageStart, beforeStorageObject,
    onProgress = async () => {} }) {
  if (!Number.isInteger(maxPrefetch) || maxPrefetch < 1 || maxPrefetch > 4
      || !Buffer.isBuffer(key) || key.length !== 32
      || !Number.isSafeInteger(limits?.maxObjectBytes) || limits.maxObjectBytes < 1
      || limits.maxObjectBytes > 64_000_000
      || ['maxAuthUsers', 'maxFirestoreReferences', 'maxStorageObjects',
        'maxStorageBytes', 'maxStorageListPages'].some((name) =>
        !Number.isSafeInteger(limits?.[name]) || limits[name] < 1)) {
    throw new Error('Invalid segmented export limits');
  }
  const directory = dirname(outputPath);
  await mkdir(directory, { mode: 0o700, recursive: false }).catch((error) => {
    if (error.code !== 'EEXIST') throw error;
  });
  const dir = await lstat(directory);
  if (!dir.isDirectory() || (dir.mode & 0o077) !== 0) throw new Error('Bundle directory must be private');
  try {
    await lstat(outputPath);
    throw new Error('Completed bundle index already exists');
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const metadataPath = join(directory, 'metadata.clrsenc');
  const metadata = await inspectSealedShard(metadataArchive, key, { scope: 'metadata', source,
    maxAuthUsers: limits.maxAuthUsers, maxFirestoreDocuments: limits.maxFirestoreReferences });
  if (metadataArchive !== metadataPath) {
    await link(metadataArchive, metadataPath).catch(async (error) => {
      if (error.code !== 'EEXIST') throw error;
      const existing = await inspectSealedShard(metadataPath, key, { scope: 'metadata', source });
      if (existing.ciphertextSha256 !== metadata.ciphertextSha256) {
        throw new Error('Bundle metadata cannot be replaced');
      }
    });
  }
  metadata.file = 'metadata.clrsenc';
  const counters = { pages: 0 };
  const captured = await inventory(bucket, source, key, limits, counters);
  const state = { status: 'storage', objectsTotal: captured.objects.length,
    bytesTotal: captured.bytes, completed: 0, reused: 0, downloaded: 0,
    completedBytes: 0, active: 0, preservedIncomplete: 0 };
  await onProgress({ ...state });
  const reusableEntries = new Map();
  const invalidEntries = new Set();
  let cachedSourceBytes = 0;
  // Validate reusable ciphertext before accounting for it in the disk budget.
  // Retry reserves only the unread part of the SAME total cap, plus 2 GiB.
  for (const item of captured.objects) {
    const path = join(directory, `storage-${item.identity}.clrsenc`);
    try {
      const entry = await inspectSealedShard(path, key, { scope: 'storage', source,
        identity: item.identity, expectedSize: item.size });
      reusableEntries.set(item.identity, entry); cachedSourceBytes += item.size;
    } catch (error) { if (error.code !== 'ENOENT') invalidEntries.add(item.identity); }
  }
  if (beforeStorageStart) await beforeStorageStart(limits.maxStorageBytes - cachedSourceBytes);
  const entries = new Array(captured.objects.length);
  let cursor = 0;
  let failure;
  let reservedBytes = 0;
  async function one(item) {
    const path = join(directory, `storage-${item.identity}.clrsenc`);
    if (reusableEntries.has(item.identity)) {
      state.reused++; return reusableEntries.get(item.identity);
    }
    if (invalidEntries.has(item.identity)) {
        // A corrupt/unfinished previously sealed file remains available for
        // diagnosis, but is never accepted or overwritten as a reusable shard.
        await rename(path, path + `.rejected-${randomBytes(8).toString('hex')}`).catch((missing) => {
          if (missing.code !== 'ENOENT') throw missing;
        });
    }
    reservedBytes += item.size;
    let writer;
    try {
      if (beforeStorageObject) await beforeStorageObject(reservedBytes);
      writer = await retainedWriter(path, key, () => { state.preservedIncomplete++; });
      const single = {
        async getFiles() { return [[{ name: item.name, metadata: item.metadata }], null]; },
        file(name, options) {
          const pinned = bucket.file(name, options);
          return { createReadStream(readOptions) {
            const stream = pinned.createReadStream(readOptions);
            if (typeof stream.destroy !== 'function' || typeof stream.once !== 'function') return stream;
            const timer = setTimeout(() => stream.destroy(new Error('Storage read timed out')), 60000);
            timer.unref(); stream.once('close', () => clearTimeout(timer));
            stream.once('end', () => clearTimeout(timer)); return stream;
          } };
        },
      };
      await exportFirebase({ bucket: single, writer, project: source.project,
        database: source.database, bucketName: source.bucket, scope: 'storage', storagePrefix: '',
        limits: { ...limits, maxStorageObjects: 1, maxStorageBytes: Math.max(1, item.size) } });
      const sealed = await inspectSealedShard(path, key, { scope: 'storage', source,
        identity: item.identity, expectedSize: item.size });
      state.downloaded++; return sealed;
    } finally {
      reservedBytes -= item.size;
      if (writer) await writer.abort();
    }
  }
  async function worker() {
    while (!failure && cursor < captured.objects.length) {
      const index = cursor++; const item = captured.objects[index]; state.active++;
      try {
        entries[index] = await one(item); state.completed++; state.completedBytes += item.size;
      } catch (error) { failure ??= error; }
      finally {
        state.active--;
        try { await onProgress({ ...state }); } catch (error) { failure ??= error; }
      }
    }
  }
  await Promise.all(Array.from({ length: maxPrefetch }, worker));
  if (failure) {
    await onProgress({ ...state, status: 'failed', errorClassification: classifyExportFailure(failure) });
    throw failure;
  }
  await onProgress({ ...state, status: 'checking_source_drift' });
  const current = await inventory(bucket, source, key, limits, counters);
  const currentIds = new Set(current.objects.map((row) => row.identity));
  if (currentIds.size !== captured.objects.length || captured.objects.some((row) => !currentIds.has(row.identity))) {
    throw new Error('Storage inventory changed during export');
  }
  const summary = { ...metadata.summary, storageObjects: captured.objects.length,
    storageBytes: captured.bytes, storageListPages: counters.pages };
  const fullSource = { ...metadata.sourceRecord, scope: 'all', completeSource: true,
    segmented: true, snapshotConsistent: false, finalSyncRequired: true,
    storageCapturedAt: new Date().toISOString() };
  const strip = ({ summary: ignoredSummary, sourceRecord: ignoredSource, ...entry }) => entry;
  const descriptor = { kind: 'archive-bundle', format: 1, source: fullSource, summary,
    shards: [strip(metadata), ...entries.map(strip)] };
  const indexWriter = await retainedWriter(outputPath, key, () => {});
  try {
    await indexWriter.writeJson(descriptor);
    await indexWriter.finish({ indexShards: descriptor.shards.length });
  } finally { await indexWriter.abort(); }
  await onProgress({ ...state, status: 'export_complete', summary });
  return summary;
}
