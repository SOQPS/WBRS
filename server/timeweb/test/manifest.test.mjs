import test from 'node:test';
import assert from 'node:assert/strict';
import { collectManifest, compareManifests, firebaseStorageObject,
  fingerprint } from '../manifest.mjs';

const key = Buffer.alloc(32, 7);
const bucketName = 'demo-bucket.appspot.com';

class FakeDocument {
  constructor(path, data, children = []) {
    this.path = path;
    this.id = path.split('/').at(-1);
    this.content = data;
    this.children = children;
  }
  async get() { return { exists: this.content !== null, data: () => this.content }; }
  async listCollections() { return this.children; }
}

class FakeCollection {
  constructor(id, documents) { this.id = id; this.documents = documents; }
  async listDocuments() { return this.documents; }
}

function fixture() {
  const avatar = `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/avatars%2Fone.jpg?alt=media&token=private-token`;
  const users = new FakeCollection('users', [
    new FakeDocument('users/u1', {
      uid: 'u1', email: 'person@example.invalid', profilePic: avatar,
      about: 'PRIVATE PROFILE TEXT',
    }, [new FakeCollection('images', [
      new FakeDocument('users/u1/images/first', { url: avatar }),
    ])]),
    // Firestore can have a subcollection under a missing parent document.
    new FakeDocument('users/orphan-parent', null, [new FakeCollection('notifications', [
      new FakeDocument('users/orphan-parent/notifications/n1', { body: 'PRIVATE NOTICE' }),
    ])]),
  ]);
  const chats = new FakeCollection('chats', [
    new FakeDocument('chats/c1', { user1: 'u1', user2: 'u2' }, [
      new FakeCollection('chats', [new FakeDocument('chats/c1/chats/m1', {
        sendByID: 'u1', message: 'PRIVATE CHAT MESSAGE',
      })]),
    ]),
  ]);
  const meets = new FakeCollection('meets', [
    new FakeDocument('meets/mt1', { admin: 'u1', users: ['u1', 'u2'] }),
  ]);
  return {
    auth: {
      async listUsers(_pageSize, token) {
        return token ? {
          users: [{ uid: 'u2', email: 'other@example.invalid', disabled: false,
            providerData: [{ providerId: 'password' }] }],
        } : {
          users: [{ uid: 'u1', email: 'person@example.invalid', disabled: false,
            providerData: [{ providerId: 'password' }],
            customClaims: { admin: true }, passwordHash: Buffer.from('secret') }],
          pageToken: 'page-two',
        };
      },
    },
    firestore: { async listCollections() { return [users, chats, meets]; } },
    bucket: {
      async getFiles(query) {
        if (query.pageToken) return [[{
          name: 'unused.jpg', metadata: { size: '5' },
        }], null];
        return [[{
          name: 'avatars/one.jpg', metadata: { size: '100', md5Hash: 'raw-md5' },
        }], { pageToken: 'page-two' }];
      },
    },
    bucketName, key, projectId: 'demo-clrs-local',
    maxAuthUsers: 100, maxAuthListPages: 10,
    maxDocuments: 100, maxObjects: 100,
  };
}

test('recursive inventory keeps counts, links and hashes without raw personal data', async () => {
  const manifest = await collectManifest(fixture());
  assert.equal(manifest.auth.count, 2);
  assert.equal(manifest.schemaVersion, 2);
  assert.equal(Object.hasOwn(manifest.auth.users[0], 'passwordHashAvailable'), false);
  assert.equal(manifest.firestore.count, 6);
  assert.deepEqual(manifest.firestore.countsByCollection, {
    users: 1, chats: 1, meets: 1, 'users/{id}/images': 1,
    'users/{id}/notifications': 1, 'chats/{id}/chats': 1,
  });
  assert.equal(manifest.storage.count, 2);
  assert.equal(manifest.storage.bytes, 105);
  assert.deepEqual(manifest.links.authWithoutProfile, [fingerprint(key, 'uid', 'u2')]);
  assert.deepEqual(manifest.links.profileWithoutAuth, []);
  assert.equal(manifest.links.unresolvedUserRefs.length, 0);
  assert.deepEqual(manifest.links.missingStorageObjects, []);
  const serialized = JSON.stringify(manifest);
  for (const secret of ['PRIVATE', 'person@example.invalid', 'u1', 'avatars/one.jpg',
    'private-token', 'raw-md5', 'secret']) {
    assert.equal(serialized.includes(secret), false, secret);
  }
  assert.equal(compareManifests(manifest, structuredClone(manifest)).equal, true);
});

test('missing storage and user links are reported only as fingerprints', async () => {
  const input = fixture();
  input.firestore.listCollections = async () => [new FakeCollection('users', [
    new FakeDocument('users/u3', { uid: 'u3', profilePic: `gs://${bucketName}/missing.jpg` }),
  ])];
  const manifest = await collectManifest(input);
  assert.deepEqual(manifest.links.profileWithoutAuth, [fingerprint(key, 'uid', 'u3')]);
  assert.deepEqual(manifest.links.missingStorageObjects,
    [fingerprint(key, 'object', 'missing.jpg')]);
  assert.equal(manifest.links.unresolvedUserRefs.length, 1);
  assert.equal(manifest.links.unresolvedUserRefs[0].uid, fingerprint(key, 'uid', 'u3'));
});

test('comparison catches missing, extra and changed records', async () => {
  const source = await collectManifest(fixture());
  const target = structuredClone(source);
  target.firestore.documents[0].content = fingerprint(key, 'document-content', 'changed');
  target.storage.objects.pop();
  target.storage.count = 1;
  target.storage.bytes = 100;
  const result = compareManifests(source, target);
  assert.equal(result.equal, false);
  assert.ok(result.differences.some((item) => item.startsWith('firestore.documents:changed:')));
  assert.ok(result.differences.some((item) => item.startsWith('storage.objects:missing:')));
  assert.ok(result.differences.includes('storage.count'));
});

test('inventory enforces explicit limits before returning incomplete manifest', async () => {
  await assert.rejects(collectManifest({ ...fixture(), maxAuthUsers: 1 }),
    /Auth user limit reached/);
  await assert.rejects(collectManifest({ ...fixture(), maxAuthListPages: 1 }),
    /Auth list-page limit reached/);
  await assert.rejects(collectManifest({ ...fixture(), maxDocuments: 2 }),
    /Firestore read limit reached/);
  await assert.rejects(collectManifest({ ...fixture(), maxObjects: 1 }),
    /Storage listing limit reached/);
  await assert.rejects(collectManifest({ ...fixture(), key: Buffer.alloc(4) }),
    /HMAC key/);
  const input = fixture();
  input.firestore.listCollections = async () => [new FakeCollection('users', [
    new FakeDocument('users/missing-one', null),
    new FakeDocument('users/missing-two', null),
  ])];
  await assert.rejects(collectManifest({ ...input, maxDocuments: 1 }),
    /Firestore read limit reached/);
});

test('inventory stops repeated empty Auth pages', async () => {
  const input = fixture();
  input.auth.listUsers = async () => ({ users: [], pageToken: 'same-page' });
  await assert.rejects(collectManifest(input), /repeated Auth page token/);
});

test('comparison rejects incomplete and duplicated manifests instead of reporting equality', async () => {
  const source = await collectManifest(fixture());
  assert.throws(() => compareManifests({ schemaVersion: 2 }, { schemaVersion: 2 }),
    /Invalid manifest/);
  const truncated = structuredClone(source);
  truncated.firestore.documents.pop();
  assert.throws(() => compareManifests(source, truncated), /Invalid manifest count/);
  const duplicate = structuredClone(source);
  duplicate.auth.users[1] = structuredClone(duplicate.auth.users[0]);
  assert.throws(() => compareManifests(source, duplicate), /Invalid manifest identity/);
  const anotherKey = structuredClone(source);
  anotherKey.hmacKeyId = fingerprint(Buffer.alloc(32, 8), 'manifest-key', 'CLRS manifest v2');
  assert.ok(compareManifests(source, anotherKey).differences.includes('hmacKeyId'));
});

test('storage URL extraction ignores tokens and foreign hosts', () => {
  assert.equal(firebaseStorageObject(
    `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/a%2Fb.png?token=private`,
    bucketName), 'a/b.png');
  assert.equal(firebaseStorageObject(`gs://${bucketName}/a/b.png`, bucketName), 'a/b.png');
  assert.equal(firebaseStorageObject('https://example.com/a.png', bucketName), null);
});
