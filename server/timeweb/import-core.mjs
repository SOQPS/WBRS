import { createHash } from 'node:crypto';
import { readEncryptedArchive } from './encrypted-archive.mjs';

export const DEFAULT_IMPORT_LIMITS = Object.freeze({
  maxAuthUsers: 100_000,
  maxFirestoreDocuments: 2_000_000,
  maxStorageObjects: 200_000,
  maxStorageBytes: 100_000_000_000,
  maxObjectBytes: 64_000_000,
});

function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function nonnegativeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (object(value)) {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}

export function payloadHash(value) {
  return createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
}

export function targetObjectKey(project, bucket, sourcePath) {
  const hash = createHash('sha256').update(project).update('\0')
    .update(bucket).update('\0').update(sourcePath).digest('hex');
  // Raw imports are quarantined until a later reviewed promotion. No API may
  // sign or serve reads from this prefix, including after a failed import.
  return `clrs-import-quarantine/${hash}`;
}

function checkedLimits(limits) {
  const result = { ...DEFAULT_IMPORT_LIMITS, ...limits };
  for (const [name, value] of Object.entries(result)) {
    if (!Number.isSafeInteger(value) || value < 1) throw new Error(`Invalid ${name}`);
  }
  return result;
}

function checkSource(source) {
  if (!object(source) || source.kind !== 'source' || source.format !== 2
      || source.scope !== 'all' || source.completeSource !== true
      || source.storagePrefix !== '' || source.passwordHashesIncluded !== false
      || !source.project || !source.database || !source.bucket
      || typeof source.project !== 'string' || typeof source.database !== 'string'
      || typeof source.bucket !== 'string') {
    throw new Error('Archive does not contain a complete CLRSX2 source');
  }
  return source;
}

function checkDocument(record) {
  const parts = typeof record.path === 'string' ? record.path.split('/') : [];
  if (parts.length < 2 || parts.length % 2 !== 0 || parts.some((part) => !part)
      || !object(record.fields) || typeof record.createTime !== 'string'
      || typeof record.updateTime !== 'string') {
    throw new Error('Invalid typed Firestore document');
  }
  return {
    firebasePath: record.path,
    parentPath: parts.length > 2 ? parts.slice(0, -2).join('/') : null,
    collectionPath: parts.slice(0, -1).join('/'),
    documentId: parts.at(-1),
    encodedPayload: {
      fields: record.fields,
      createTime: record.createTime,
      updateTime: record.updateTime,
    },
  };
}

function checkStorage(record, limits) {
  if (typeof record.name !== 'string' || !record.name || !object(record.metadata)
      || !record.metadata.generation) throw new Error('Invalid Storage object metadata');
  const size = Number(record.metadata.size);
  if (!nonnegativeInteger(size) || size > limits.maxObjectBytes) {
    throw new Error('Storage object exceeds import limit');
  }
  return { name: record.name, metadata: record.metadata, size };
}

function checkEnd(record, counts) {
  if (!object(record?.summary)) throw new Error('Invalid archive completion summary');
  const summary = record.summary;
  for (const name of ['authUsers', 'authListPages', 'firestoreDocuments',
    'firestoreMissingParents', 'firestoreReferences', 'firestoreCollections',
    'firestoreListPages', 'storageObjects', 'storageBytes', 'storageListPages']) {
    if (!nonnegativeInteger(summary[name])) throw new Error('Invalid archive completion summary');
  }
  for (const name of ['authUsers', 'firestoreDocuments', 'storageObjects', 'storageBytes']) {
    if (summary[name] !== counts[name]) throw new Error('Archive completion count mismatch');
  }
  if (summary.firestoreDocuments + summary.firestoreMissingParents
      !== summary.firestoreReferences) {
    throw new Error('Firestore reference count mismatch');
  }
  return summary;
}

// A full authenticated read is required before callers may open a DB transaction
// or write S3 objects. Nothing decrypted is written to a local file.
export async function scanImportArchive({ archivePath, key, limits, onAuth, onDocument, onObject }) {
  const cap = checkedLimits(limits);
  const encryptedHash = createHash('sha256');
  const seenAuth = new Set();
  const seenDocuments = new Set();
  const seenObjects = new Set();
  const counts = { authUsers: 0, firestoreDocuments: 0, storageObjects: 0, storageBytes: 0 };
  let source;
  let summary;
  let section = 'source';
  let pending = null;
  for await (const frame of readEncryptedArchive(archivePath, key, {
    onCiphertext: (bytes) => encryptedHash.update(bytes),
  })) {
    if (frame.type === 'bytes') {
      if (!pending) throw new Error('Unexpected Storage bytes');
      const bytes = frame.bytes;
      if (bytes.length > pending.size - pending.received) {
        throw new Error('Storage size mismatch');
      }
      pending.received += bytes.length;
      pending.hash.update(bytes);
      if (onObject) pending.chunks.push(bytes);
      continue;
    }

    const record = frame.record;
    if (!object(record)) throw new Error('Invalid archive record');
    if (section === 'source') {
      source = checkSource(record);
      section = 'auth';
      continue;
    }
    if (pending) {
      if (record.kind !== 'storage-sha256' || record.name !== pending.name
          || !/^[a-f0-9]{64}$/.test(record.sha256 ?? '')
          || pending.received !== pending.size
          || pending.hash.digest('hex') !== record.sha256) {
        throw new Error('Storage checksum or size mismatch');
      }
      counts.storageObjects++;
      counts.storageBytes += pending.size;
      if (counts.storageObjects > cap.maxStorageObjects
          || counts.storageBytes > cap.maxStorageBytes) {
        throw new Error('Storage import limit reached');
      }
      if (onObject) {
        await onObject({
          source, name: pending.name, metadata: pending.metadata,
          size: pending.size, sha256: record.sha256,
          targetKey: targetObjectKey(source.project, source.bucket, pending.name),
          bytes: Buffer.concat(pending.chunks, pending.size),
        });
      }
      pending = null;
      continue;
    }

    if (record.kind === 'auth-user' && section === 'auth') {
      const user = record.user;
      if (!object(user) || typeof user.uid !== 'string' || !user.uid
          || 'passwordHash' in user || 'passwordSalt' in user
          || seenAuth.has(user.uid)) throw new Error('Invalid or duplicate Auth UID');
      seenAuth.add(user.uid);
      if (++counts.authUsers > cap.maxAuthUsers) throw new Error('Auth import limit reached');
      if (onAuth) await onAuth({ uid: user.uid, encodedPayload: user,
        sha256: payloadHash(user) });
      continue;
    }
    if (record.kind === 'firestore-document' && ['auth', 'documents'].includes(section)) {
      section = 'documents';
      const document = checkDocument(record);
      if (seenDocuments.has(document.firebasePath)) throw new Error('Duplicate Firestore path');
      seenDocuments.add(document.firebasePath);
      if (++counts.firestoreDocuments > cap.maxFirestoreDocuments) {
        throw new Error('Firestore import limit reached');
      }
      if (onDocument) await onDocument({ ...document,
        sha256: payloadHash(document.encodedPayload) });
      continue;
    }
    if (record.kind === 'storage-object' && ['auth', 'documents', 'storage'].includes(section)) {
      section = 'storage';
      const storage = checkStorage(record, cap);
      if (seenObjects.has(storage.name)) throw new Error('Duplicate Storage path');
      seenObjects.add(storage.name);
      pending = { ...storage, received: 0, hash: createHash('sha256'), chunks: [] };
      continue;
    }
    if (record.kind === 'end' && section !== 'end') {
      summary = checkEnd(record, counts);
      section = 'end';
      continue;
    }
    throw new Error('Unexpected archive record order');
  }
  if (section !== 'end' || pending) throw new Error('Incomplete archive');
  return { source, summary, counts, archiveSha256: encryptedHash.digest('hex') };
}
