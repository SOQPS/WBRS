import { createHash, createHmac } from 'node:crypto';
import { lstat, realpath } from 'node:fs/promises';
import { dirname, join } from 'node:path';

const integer = (value) => Number.isSafeInteger(value) && value >= 0;
const hash = (value) => /^[a-f0-9]{64}$/.test(value ?? '');

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(
    Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
}

// Include exact metadata (including metageneration), not just content bytes:
// a changed download token or other metadata must not reuse an older shard.
export function storageShardIdentity(key, source, name, metadata) {
  return createHmac('sha256', key).update('CLRS sealed Storage shard v1\0')
    .update(JSON.stringify(canonical({ project: source.project, bucket: source.bucket,
      name, metadata }))).digest('hex');
}

function checkDescriptor(value) {
  if (value?.format !== 1 || !Array.isArray(value.shards)
      || value.shards.length < 1 || value.shards.length > 10001
      || value.source?.kind !== 'source' || value.source.scope !== 'all'
      || value.source.completeSource !== true || value.source.format !== 2
      || value.source.snapshotConsistent !== false || value.source.finalSyncRequired !== true
      || !value.summary || value.shards[0]?.scope !== 'metadata') {
    throw new Error('Invalid sealed archive descriptor');
  }
  const names = new Set();
  let bytes = 0;
  for (const [index, shard] of value.shards.entries()) {
    if (!/^(?:metadata|storage-[a-f0-9]{64})\.clrsenc$/.test(shard.file ?? '')
        || names.has(shard.file) || !integer(shard.ciphertextBytes)
        || shard.ciphertextBytes < 16 || !hash(shard.ciphertextSha256)
        || (index === 0 ? shard.file !== 'metadata.clrsenc'
          : shard.scope !== 'storage' || !hash(shard.objectIdentity)
            || shard.file !== `storage-${shard.objectIdentity}.clrsenc`)) {
      throw new Error('Invalid sealed archive shard');
    }
    names.add(shard.file); bytes += shard.ciphertextBytes;
    if (!Number.isSafeInteger(bytes) || bytes > 9_000_000_000) {
      throw new Error('Sealed archive size limit reached');
    }
  }
}

function sameSource(actual, expected, scope) {
  return actual?.kind === 'source' && actual.format === 2 && actual.scope === scope
    && actual.completeSource === false && actual.passwordHashesIncluded === false
    && actual.storagePrefix === '' && actual.project === expected.project
    && actual.database === expected.database && actual.bucket === expected.bucket;
}

function addCounts(summary, destination) {
  for (const name of ['authUsers', 'authListPages', 'firestoreDocuments',
    'firestoreMissingParents', 'firestoreReferences', 'firestoreCollections',
    'firestoreListPages', 'storageObjects', 'storageBytes', 'storageListPages']) {
    if (!integer(summary?.[name])) throw new Error('Invalid shard completion counts');
    destination[name] = (destination[name] ?? 0) + summary[name];
  }
}

export async function* readArchiveBundle({ path, key, descriptor,
    indexIterator, readPhysical, options }) {
  checkDescriptor(descriptor);
  // Authenticate the complete index before exposing any source/data. An index
  // without its own end marker, with trailing frames or changed order is rejected.
  const indexEnd = await indexIterator.next();
  if (indexEnd.done || indexEnd.value.type !== 'json'
      || indexEnd.value.record?.kind !== 'end'
      || indexEnd.value.record.summary?.indexShards !== descriptor.shards.length
      || !(await indexIterator.next()).done) throw new Error('Unsealed archive index');
  const directory = await realpath(dirname(path));
  const counts = {};
  yield { type: 'json', record: descriptor.source };
  for (const shard of descriptor.shards) {
    const shardPath = join(directory, shard.file);
    const file = await lstat(shardPath);
    if (!file.isFile() || (file.mode & 0o077) !== 0
        || file.size !== shard.ciphertextBytes
        || await realpath(shardPath) !== shardPath) {
      throw new Error('Missing or unsafe sealed archive shard');
    }
    const digest = createHash('sha256');
    let first = true;
    let end = false;
    let objects = 0;
    let shardSummary;
    for await (const frame of readPhysical(shardPath, key, {
      onCiphertext: (bytes) => { digest.update(bytes); options.onCiphertext?.(bytes); },
    })) {
      if (first) {
        first = false;
        if (frame.type !== 'json' || !sameSource(frame.record, descriptor.source, shard.scope)) {
          throw new Error('Archive shard belongs to another source');
        }
        continue;
      }
      if (frame.type === 'json' && frame.record?.kind === 'end') {
        end = true; shardSummary = frame.record.summary; continue;
      }
      if (end || (shard.scope === 'metadata' && (frame.type !== 'json'
          || !['auth-user', 'firestore-document'].includes(frame.record?.kind)))
          || (shard.scope === 'storage' && frame.type === 'json'
            && !['storage-object', 'storage-sha256'].includes(frame.record?.kind))) {
        throw new Error('Invalid archive shard section');
      }
      if (frame.type === 'json' && frame.record?.kind === 'storage-object') {
        objects++;
        if (storageShardIdentity(key, descriptor.source, frame.record.name,
          frame.record.metadata) !== shard.objectIdentity) {
          throw new Error('Storage shard identity mismatch');
        }
      }
      yield frame;
    }
    if (!end || digest.digest('hex') !== shard.ciphertextSha256
        || (shard.scope === 'storage' && (objects !== 1
          || shardSummary?.storageObjects !== 1 || shardSummary?.authUsers !== 0
          || shardSummary?.firestoreDocuments !== 0))
        || (shard.scope === 'metadata' && shardSummary?.storageObjects !== 0)) {
      throw new Error('Archive shard checksum or count mismatch');
    }
    addCounts(shardSummary, counts);
  }
  // Per-object shard list reads are local; the descriptor retains the real
  // bounded source-inventory page count, rather than claiming N source pages.
  counts.storageListPages = descriptor.summary.storageListPages;
  for (const [name, value] of Object.entries(counts)) {
    if (!integer(descriptor.summary[name]) || descriptor.summary[name] !== value) {
      throw new Error('Sealed archive aggregate count mismatch');
    }
  }
  yield { type: 'json', record: { kind: 'end', summary: descriptor.summary } };
}
