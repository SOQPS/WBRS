import { createHmac } from 'node:crypto';

const USER_FIELDS = new Set([
  'uid', 'fromUid', 'toUid', 'ownerUid', 'invitedUid', 'user1', 'user2',
  'sendByID', 'lastMessageSendByID', 'recipientId', 'actorUid', 'targetUid',
]);

export function fingerprint(key, kind, value) {
  return createHmac('sha256', key).update(`${kind}\0${value}`).digest('hex');
}

function normalized(value) {
  if (value === null || value === undefined) return value ?? null;
  if (value instanceof Date) return { type: 'date', value: value.toISOString() };
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) {
    return { type: 'bytes', value: Buffer.from(value).toString('base64') };
  }
  if (Array.isArray(value)) return value.map(normalized);
  if (typeof value === 'number' && !Number.isFinite(value)) {
    return { type: 'number', value: String(value) };
  }
  if (typeof value !== 'object') return value;
  if (Number.isInteger(value.seconds) && Number.isInteger(value.nanoseconds)
      && typeof value.toDate === 'function') {
    return { type: 'timestamp', seconds: value.seconds, nanoseconds: value.nanoseconds };
  }
  if (typeof value.latitude === 'number' && typeof value.longitude === 'number') {
    return { type: 'geopoint', latitude: value.latitude, longitude: value.longitude };
  }
  if (typeof value.path === 'string' && value.firestore) {
    return { type: 'reference', path: value.path };
  }
  const out = {};
  for (const field of Object.keys(value).sort()) out[field] = normalized(value[field]);
  return out;
}

export function firebaseStorageObject(value, bucketName) {
  if (typeof value !== 'string') return null;
  if (value.startsWith(`gs://${bucketName}/`)) {
    return value.slice(bucketName.length + 6);
  }
  try {
    const url = new URL(value);
    if (url.hostname !== 'firebasestorage.googleapis.com') return null;
    const prefix = `/v0/b/${encodeURIComponent(bucketName)}/o/`;
    if (!url.pathname.startsWith(prefix)) return null;
    return decodeURIComponent(url.pathname.slice(prefix.length));
  } catch {
    return null;
  }
}

function collectStorageLinks(value, bucketName, keys, seen = new WeakSet()) {
  if (typeof value === 'string') {
    const key = firebaseStorageObject(value, bucketName);
    if (key !== null) keys.add(key);
  } else if (Array.isArray(value)) {
    if (seen.has(value)) return;
    seen.add(value);
    for (const item of value) collectStorageLinks(item, bucketName, keys, seen);
  } else if (value && typeof value === 'object' && !Buffer.isBuffer(value)) {
    if (seen.has(value) || value instanceof Date
        || typeof value.toDate === 'function' || value.firestore) return;
    seen.add(value);
    for (const item of Object.values(value)) collectStorageLinks(item, bucketName, keys, seen);
  }
}

function collectUserLinks(path, data, targets) {
  if (!data || typeof data !== 'object') return;
  for (const [field, value] of Object.entries(data)) {
    if (USER_FIELDS.has(field) && typeof value === 'string' && value !== '') {
      targets.push({ path, field, uid: value });
    }
  }
  if (path.startsWith('meets/') && path.split('/').length === 2
      && Array.isArray(data.users)) {
    if (typeof data.admin === 'string' && data.admin !== '') {
      targets.push({ path, field: 'admin', uid: data.admin });
    }
    for (const uid of data.users) {
      if (typeof uid === 'string' && uid !== '') targets.push({ path, field: 'users', uid });
    }
  }
}

function numericSize(raw) {
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error('Invalid object size');
  return parsed;
}

function collectionPattern(path) {
  return path.split('/').slice(0, -1)
    .map((segment, index) => index % 2 === 1 ? '{id}' : segment).join('/');
}

/** Reads only metadata and documents. No raw IDs, paths or values leave this function. */
export async function collectManifest({ auth, firestore, bucket, bucketName, key,
  projectId, maxAuthUsers, maxAuthListPages, maxDocuments, maxObjects }) {
  if (!Buffer.isBuffer(key) || key.length < 32) throw new Error('HMAC key must be at least 32 bytes');
  if (!Number.isSafeInteger(maxAuthUsers) || maxAuthUsers < 1
      || !Number.isSafeInteger(maxAuthListPages) || maxAuthListPages < 1
      || !Number.isSafeInteger(maxDocuments) || maxDocuments < 1
      || !Number.isSafeInteger(maxObjects) || maxObjects < 1) {
    throw new Error('Explicit positive read limits are required');
  }
  const users = [];
  const rawAuthUids = new Set();
  const seenAuthTokens = new Set();
  let pageToken;
  let authListPages = 0;
  do {
    if (++authListPages > maxAuthListPages) throw new Error('Auth list-page limit reached');
    const page = await auth.listUsers(1000, pageToken);
    if (!Array.isArray(page?.users)) throw new Error('Invalid Auth page');
    for (const user of page.users) {
      if (users.length >= maxAuthUsers) throw new Error('Auth user limit reached');
      if (typeof user?.uid !== 'string' || !user.uid || rawAuthUids.has(user.uid)) {
        throw new Error('Invalid or duplicate Auth UID');
      }
      rawAuthUids.add(user.uid);
      users.push({
        uid: fingerprint(key, 'uid', user.uid),
        email: user.email ? fingerprint(key, 'email', user.email.trim().toLowerCase()) : null,
        disabled: user.disabled === true,
        emailVerified: user.emailVerified === true,
        providers: (user.providerData ?? []).map((provider) => provider.providerId).sort(),
        claims: fingerprint(key, 'claims', JSON.stringify(normalized(user.customClaims ?? {}))),
      });
    }
    pageToken = page.pageToken;
    if (pageToken !== undefined && pageToken !== null && pageToken !== '') {
      if (typeof pageToken !== 'string' || seenAuthTokens.has(pageToken)) {
        throw new Error('Invalid or repeated Auth page token');
      }
      seenAuthTokens.add(pageToken);
    }
  } while (pageToken);
  users.sort((a, b) => a.uid.localeCompare(b.uid));

  const documents = [];
  const countsByCollection = {};
  const rawProfileUids = new Set();
  const userLinks = [];
  const storageLinks = new Set();
  let documentReads = 0;
  const collections = [...await firestore.listCollections()];
  for (let cursor = 0; cursor < collections.length; cursor++) {
    const collection = collections[cursor];
    for (const ref of await collection.listDocuments()) {
      // A missing parent can still have subcollections. It is a read even though
      // it does not add a document to the manifest.
      if (documentReads >= maxDocuments) throw new Error('Firestore read limit reached');
      documentReads++;
      const snap = await ref.get();
      if (snap.exists) {
        const data = snap.data();
        const pattern = collectionPattern(ref.path);
        documents.push({
          path: fingerprint(key, 'document', ref.path),
          collection: pattern,
          content: fingerprint(key, 'document-content', JSON.stringify(normalized(data))),
        });
        countsByCollection[pattern] = (countsByCollection[pattern] ?? 0) + 1;
        if (ref.path.startsWith('users/') && ref.path.split('/').length === 2) {
          rawProfileUids.add(ref.id);
        }
        collectUserLinks(ref.path, data, userLinks);
        collectStorageLinks(data, bucketName, storageLinks);
      }
      collections.push(...await ref.listCollections());
    }
  }
  documents.sort((a, b) => a.path.localeCompare(b.path));

  const objects = [];
  const rawObjectKeys = new Set();
  let nextQuery = { autoPaginate: false, maxResults: 500 };
  while (nextQuery) {
    const [files, following] = await bucket.getFiles(nextQuery);
    for (const file of files) {
      if (objects.length >= maxObjects) throw new Error('Storage listing limit reached');
      const size = numericSize(file.metadata?.size);
      rawObjectKeys.add(file.name);
      objects.push({
        key: fingerprint(key, 'object', file.name),
        bytes: size,
        checksum: file.metadata?.md5Hash
          ? fingerprint(key, 'md5', file.metadata.md5Hash) : null,
      });
    }
    nextQuery = following ? { ...following, autoPaginate: false, maxResults: 500 } : null;
  }
  objects.sort((a, b) => a.key.localeCompare(b.key));

  const unresolvedUserRefs = userLinks
    .filter(({ uid }) => !rawAuthUids.has(uid))
    .map(({ path, field, uid }) => ({
      document: fingerprint(key, 'document', path), field,
      uid: fingerprint(key, 'uid', uid),
    })).sort((a, b) => a.document.localeCompare(b.document) || a.field.localeCompare(b.field));
  const missingStorageObjects = [...storageLinks]
    .filter((object) => !rawObjectKeys.has(object))
    .map((object) => fingerprint(key, 'object', object)).sort();
  const authWithoutProfile = [...rawAuthUids]
    .filter((uid) => !rawProfileUids.has(uid))
    .map((uid) => fingerprint(key, 'uid', uid)).sort();
  const profileWithoutAuth = [...rawProfileUids]
    .filter((uid) => !rawAuthUids.has(uid))
    .map((uid) => fingerprint(key, 'uid', uid)).sort();
  return {
    schemaVersion: 2,
    hmacKeyId: fingerprint(key, 'manifest-key', 'CLRS manifest v2'),
    source: {
      project: fingerprint(key, 'project', projectId),
      bucket: fingerprint(key, 'bucket', bucketName),
    },
    auth: { count: users.length, users },
    firestore: { count: documents.length, countsByCollection, documents },
    storage: { count: objects.length,
      bytes: objects.reduce((total, object) => total + object.bytes, 0), objects },
    links: { authWithoutProfile, profileWithoutAuth, unresolvedUserRefs,
      missingStorageObjects },
  };
}

const FINGERPRINT = /^[0-9a-f]{64}$/;

function validateManifest(manifest) {
  if (!manifest || manifest.schemaVersion !== 2
      || !FINGERPRINT.test(manifest.hmacKeyId)
      || !FINGERPRINT.test(manifest.source?.project)
      || !FINGERPRINT.test(manifest.source?.bucket)) {
    throw new Error('Invalid manifest header');
  }
  const sections = [
    ['auth', 'users', 'uid'], ['firestore', 'documents', 'path'],
    ['storage', 'objects', 'key'],
  ];
  for (const [section, rows, id] of sections) {
    const part = manifest[section];
    if (!part || !Array.isArray(part[rows])
        || !Number.isSafeInteger(part.count) || part.count < 0
        || part.count !== part[rows].length) {
      throw new Error('Invalid manifest count');
    }
    const identities = new Set();
    for (const row of part[rows]) {
      if (!row || !FINGERPRINT.test(row[id]) || identities.has(row[id])) {
        throw new Error('Invalid manifest identity');
      }
      identities.add(row[id]);
    }
  }
  const collectionCounts = manifest.firestore.countsByCollection;
  const actualCollectionCounts = {};
  for (const doc of manifest.firestore.documents) {
    if (typeof doc.collection !== 'string' || doc.collection === ''
        || !FINGERPRINT.test(doc.content)) throw new Error('Invalid document record');
    actualCollectionCounts[doc.collection] = (actualCollectionCounts[doc.collection] ?? 0) + 1;
  }
  if (!collectionCounts || Array.isArray(collectionCounts)
      || typeof collectionCounts !== 'object'
      || Object.values(collectionCounts).some((count) => !Number.isSafeInteger(count) || count < 0)
      || Object.values(collectionCounts).reduce((sum, count) => sum + count, 0)
        !== manifest.firestore.count
      || JSON.stringify(normalized(collectionCounts))
        !== JSON.stringify(normalized(actualCollectionCounts))) {
    throw new Error('Invalid collection counts');
  }
  if (!Number.isSafeInteger(manifest.storage.bytes) || manifest.storage.bytes < 0
      || manifest.storage.objects.some((object) => !Number.isSafeInteger(object.bytes)
        || object.bytes < 0 || (object.checksum !== null
          && !FINGERPRINT.test(object.checksum)))
      || manifest.storage.objects.reduce((sum, object) => sum + object.bytes, 0)
        !== manifest.storage.bytes) {
    throw new Error('Invalid storage bytes');
  }
  if (manifest.auth.users.some((user) => (user.email !== null
        && !FINGERPRINT.test(user.email))
      || !FINGERPRINT.test(user.claims)
      || typeof user.disabled !== 'boolean'
      || typeof user.emailVerified !== 'boolean'
      || !Array.isArray(user.providers)
      || user.providers.some((provider) => typeof provider !== 'string'))) {
    throw new Error('Invalid manifest record');
  }
  const links = manifest.links;
  if (!links || ['authWithoutProfile', 'profileWithoutAuth',
    'unresolvedUserRefs', 'missingStorageObjects'].some((name) => !Array.isArray(links[name]))) {
    throw new Error('Invalid manifest links');
  }
  if (['authWithoutProfile', 'profileWithoutAuth', 'missingStorageObjects']
    .some((name) => links[name].some((value) => !FINGERPRINT.test(value)))
      || links.unresolvedUserRefs.some((link) => !FINGERPRINT.test(link?.document)
        || !FINGERPRINT.test(link?.uid) || typeof link?.field !== 'string')) {
    throw new Error('Invalid manifest links');
  }
}

export function compareManifests(source, target) {
  validateManifest(source);
  validateManifest(target);
  const differences = [];
  if (source.hmacKeyId !== target.hmacKeyId) differences.push('hmacKeyId');
  for (const section of ['auth', 'firestore', 'storage']) {
    for (const metric of section === 'storage' ? ['count', 'bytes'] : ['count']) {
      if (source[section]?.[metric] !== target[section]?.[metric]) {
        differences.push(`${section}.${metric}`);
      }
    }
  }
  const paths = [
    ['auth', 'users', 'uid'], ['firestore', 'documents', 'path'],
    ['storage', 'objects', 'key'],
  ];
  for (const [section, name, keyName] of paths) {
    const left = new Map((source[section]?.[name] ?? []).map((row) => [row[keyName], row]));
    const right = new Map((target[section]?.[name] ?? []).map((row) => [row[keyName], row]));
    for (const [id, record] of left) {
      if (!right.has(id)) differences.push(`${section}.${name}:missing:${id}`);
      else if (JSON.stringify(normalized(record)) !== JSON.stringify(normalized(right.get(id)))) {
        differences.push(`${section}.${name}:changed:${id}`);
      }
    }
    for (const id of right.keys()) {
      if (!left.has(id)) differences.push(`${section}.${name}:extra:${id}`);
    }
  }
  if (JSON.stringify(normalized(source.firestore?.countsByCollection))
      !== JSON.stringify(normalized(target.firestore?.countsByCollection))) {
    differences.push('firestore.countsByCollection');
  }
  if (JSON.stringify(normalized(source.links)) !== JSON.stringify(normalized(target.links))) {
    differences.push('links');
  }
  return { equal: differences.length === 0, differences };
}
