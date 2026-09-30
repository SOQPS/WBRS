import { createHash } from 'node:crypto';

function positiveLimit(value, label) {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${label} must be an explicit positive integer`);
  }
}

function nextToken(token, seen) {
  if (!token) return null;
  if (typeof token !== 'string' || seen.has(token)) throw new Error('Repeated page token');
  seen.add(token);
  return token;
}

function authMetadata(user) {
  if (!user || typeof user.uid !== 'string' || !user.uid) {
    throw new Error('Invalid Auth user');
  }
  const json = typeof user.toJSON === 'function' ? user.toJSON() : { ...user };
  const result = { ...json, uid: user.uid };
  // Viewer grants do not supply these. Even with broader grants, this export
  // intentionally cannot be mistaken for a password-capable Auth migration.
  delete result.passwordHash;
  delete result.passwordSalt;
  return result;
}

function splitCollectionPath(collectionPath) {
  const parts = collectionPath.split('/');
  if (parts.length % 2 !== 1 || parts.some((part) => !part)) {
    throw new Error('Invalid Firestore collection path');
  }
  return parts;
}

function documentPath(name, prefix, collectionPath) {
  if (typeof name !== 'string' || !name.startsWith(`${prefix}/`)) {
    throw new Error('Firestore document belongs to another source');
  }
  const path = name.slice(prefix.length + 1);
  const suffix = path.slice(collectionPath.length + 1);
  if (!path.startsWith(`${collectionPath}/`) || !suffix || suffix.includes('/')) {
    throw new Error('Unexpected Firestore document path');
  }
  return path;
}

function objectSize(metadata) {
  const size = Number(metadata?.size);
  if (!Number.isSafeInteger(size) || size < 0) throw new Error('Invalid Storage size');
  return size;
}

async function exportAuth(auth, writer, summary, limits) {
  const seen = new Set();
  const seenUids = new Set();
  let token;
  do {
    if (++summary.authListPages > limits.maxAuthListPages) {
      throw new Error('Auth list-page limit reached');
    }
    const remaining = limits.maxAuthUsers - summary.authUsers;
    if (remaining < 1) throw new Error('Auth user limit reached');
    const page = await auth.listUsers(Math.min(1000, remaining), token);
    if (!Array.isArray(page?.users)) throw new Error('Invalid Auth page');
    for (const user of page.users) {
      const record = authMetadata(user);
      if (seenUids.has(record.uid)) throw new Error('Duplicate Auth UID');
      seenUids.add(record.uid);
      if (++summary.authUsers > limits.maxAuthUsers) throw new Error('Auth user limit reached');
      await writer.writeJson({ kind: 'auth-user', user: record });
    }
    token = nextToken(page.pageToken, seen);
    if (token && summary.authUsers === limits.maxAuthUsers) {
      throw new Error('Auth user limit reached');
    }
  } while (token);
}

async function exportFirestore(api, writer, summary, limits, project, database,
    concurrency) {
  const sourcePrefix = `projects/${project}/databases/${database}/documents`;
  const queue = [];
  const seenCollections = new Set();
  const seenDocuments = new Set();
  const active = new Set();
  let failure;
  let writes = Promise.resolve();
  let notify;
  let available;
  const resetNotification = () => {
    available = new Promise((resolve) => { notify = resolve; });
  };
  resetNotification();
  const checkRunning = () => { if (failure) throw failure; };
  const writeDocument = (record) => {
    // AES-GCM frame offsets/nonces must never be written concurrently. Each
    // worker waits for this chain before issuing its next child-list request.
    writes = writes.then(async () => {
      checkRunning();
      await writer.writeJson(record);
    });
    return writes;
  };

  async function addCollections(parent) {
    const tokens = new Set();
    let token;
    do {
      checkRunning();
      if (++summary.firestoreListPages > limits.maxFirestoreListPages) {
        throw new Error('Firestore list-page limit reached');
      }
      const page = await api.listCollectionIds(parent, token);
      checkRunning();
      if (!Array.isArray(page?.collectionIds)) throw new Error('Invalid collection page');
      for (const id of page.collectionIds) {
        if (typeof id !== 'string' || !id || id.includes('/')) {
          throw new Error('Invalid collection ID');
        }
        const path = parent ? `${parent}/${id}` : id;
        splitCollectionPath(path);
        if (seenCollections.has(path)) throw new Error('Duplicate collection path');
        seenCollections.add(path);
        if (++summary.firestoreCollections > limits.maxFirestoreCollections) {
          throw new Error('Firestore collection limit reached');
        }
        queue.push(path);
        notify();
      }
      token = nextToken(page.nextPageToken, tokens);
    } while (token);
  }

  async function exportCollection(collectionPath) {
    const tokens = new Set();
    let token;
    do {
      checkRunning();
      if (++summary.firestoreListPages > limits.maxFirestoreListPages) {
        throw new Error('Firestore list-page limit reached');
      }
      const page = await api.listDocuments(collectionPath, token);
      checkRunning();
      if (!Array.isArray(page?.documents)) throw new Error('Invalid document page');
      for (const document of page.documents) {
        checkRunning();
        const path = documentPath(document.name, sourcePrefix, collectionPath);
        if (seenDocuments.has(path)) throw new Error('Duplicate document path');
        seenDocuments.add(path);
        if (++summary.firestoreReferences > limits.maxFirestoreReferences) {
          throw new Error('Firestore reference limit reached');
        }
        const missing = !document.createTime && !document.updateTime
          && document.fields === undefined;
        if (!missing) {
          if (!document.createTime || !document.updateTime
              || (document.fields !== undefined
                && (typeof document.fields !== 'object'
                  || document.fields === null || Array.isArray(document.fields)))) {
            throw new Error('Invalid typed Firestore document');
          }
          await writeDocument({
            kind: 'firestore-document', path, fields: document.fields ?? {},
            createTime: document.createTime, updateTime: document.updateTime,
          });
          summary.firestoreDocuments++;
        } else {
          summary.firestoreMissingParents++;
        }
        // Missing parent documents can still own real subcollections.
        await addCollections(path);
      }
      token = nextToken(page.nextPageToken, tokens);
    } while (token);
  }
  await addCollections('');
  let cursor = 0;
  while (cursor < queue.length || active.size) {
    while (!failure && cursor < queue.length && active.size < concurrency) {
      const path = queue[cursor++];
      const job = exportCollection(path).catch((error) => {
        failure ??= error;
        notify();
      }).finally(() => active.delete(job));
      active.add(job);
    }
    if (!active.size) break;
    // New child collections can become available before a large parent job
    // completes. Wake to fill spare worker slots as soon as they are queued.
    await Promise.race([...active, available]);
    resetNotification();
  }
  // All active readers are drained before the caller may abort the writer.
  // A rejected write chain is also observed, so queued frames cannot survive
  // archive abort or create an unhandled rejection.
  try { await writes; } catch (error) { failure ??= error; }
  if (failure) throw failure;
}

async function exportStorage(bucket, writer, summary, limits, prefix,
    beforeStorageObject) {
  const seenTokens = new Set();
  const seenObjects = new Set();
  let query = { autoPaginate: false, maxResults: 100, prefix };
  while (query) {
    if (++summary.storageListPages > limits.maxStorageListPages) {
      throw new Error('Storage list-page limit reached');
    }
    const [files, following] = await bucket.getFiles(query);
    if (!Array.isArray(files)) throw new Error('Invalid Storage page');
    for (const file of files) {
      if (typeof file.name !== 'string' || !file.name.startsWith(prefix)
          || seenObjects.has(file.name)) throw new Error('Invalid or duplicate Storage key');
      seenObjects.add(file.name);
      if (++summary.storageObjects > limits.maxStorageObjects) {
        throw new Error('Storage object limit reached');
      }
      const metadata = file.metadata;
      const expected = objectSize(metadata);
      if (!metadata.generation || expected > limits.maxStorageBytes - summary.storageBytes) {
        throw new Error('Storage generation missing or byte limit reached');
      }
      // Check the remaining local capacity before writing or downloading this
      // object. The callback is supplied by the CLI and is also testable with
      // an in-memory writer.
      if (beforeStorageObject) await beforeStorageObject(expected);
      await writer.writeJson({ kind: 'storage-object', name: file.name, metadata });
      const pinned = bucket.file(file.name, { generation: metadata.generation });
      const hash = createHash('sha256');
      const md5 = metadata.md5Hash ? createHash('md5') : null;
      let received = 0;
      for await (const chunk of pinned.createReadStream({ validation: 'crc32c' })) {
        if (chunk.length > expected - received
            || chunk.length > limits.maxStorageBytes - summary.storageBytes - received) {
          throw new Error('Storage byte limit or size mismatch');
        }
        received += chunk.length;
        hash.update(chunk);
        md5?.update(chunk);
        await writer.writeBytes(chunk);
      }
      if (received !== expected || (md5 && md5.digest('base64') !== metadata.md5Hash)) {
        throw new Error('Storage checksum or size mismatch');
      }
      await writer.writeJson({
        kind: 'storage-sha256', name: file.name, sha256: hash.digest('hex'),
      });
      summary.storageBytes += received;
    }
    if (following) {
      const token = nextToken(following.pageToken, seenTokens);
      if (!token) throw new Error('Storage pagination lacks a token');
      query = { ...following, autoPaginate: false, maxResults: 100, prefix };
    } else {
      query = null;
    }
  }
}

export async function exportFirebase({ auth, firestoreApi, bucket, writer,
  project, database = '(default)', bucketName, scope = 'all', storagePrefix = '',
  limits, beforeStorageObject }) {
  if (!['all', 'storage', 'metadata'].includes(scope)
      || (scope !== 'storage' && storagePrefix)) {
    throw new Error('Only storage-only exports may use a prefix');
  }
  if (!project || !bucketName || !database || typeof storagePrefix !== 'string') {
    throw new Error('Source project, database and bucket are required');
  }
  const requiredLimits = ['maxAuthUsers', 'maxAuthListPages', 'maxFirestoreCollections',
    'maxFirestoreReferences', 'maxFirestoreListPages'];
  if (scope !== 'metadata') {
    requiredLimits.push('maxStorageObjects', 'maxStorageListPages', 'maxStorageBytes');
  }
  for (const label of requiredLimits) {
    positiveLimit(limits?.[label], label);
  }
  const firestoreConcurrency = limits.maxFirestoreConcurrency ?? 1;
  if (!Number.isInteger(firestoreConcurrency) || firestoreConcurrency < 1
      || firestoreConcurrency > 8) {
    throw new Error('Firestore concurrency must be an integer from 1 to 8');
  }
  const summary = {
    authUsers: 0, authListPages: 0, firestoreDocuments: 0, firestoreMissingParents: 0,
    firestoreReferences: 0, firestoreCollections: 0, firestoreListPages: 0,
    storageObjects: 0, storageBytes: 0, storageListPages: 0,
  };
  try {
    await writer.writeJson({
      kind: 'source', format: 2, project, database, bucket: bucketName,
      scope, storagePrefix, startedAt: new Date().toISOString(),
      completeSource: scope === 'all', passwordHashesIncluded: false,
      snapshotConsistent: false,
      firestoreConcurrency,
    });
    if (scope !== 'storage') {
      await exportAuth(auth, writer, summary, limits);
      await exportFirestore(firestoreApi, writer, summary, limits, project, database,
        firestoreConcurrency);
    }
    if (scope !== 'metadata') {
      await exportStorage(bucket, writer, summary, limits, storagePrefix,
        beforeStorageObject);
    }
    await writer.finish(summary);
    return summary;
  } catch (error) {
    await writer.abort();
    throw error;
  }
}
