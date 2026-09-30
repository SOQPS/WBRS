import assert from 'node:assert/strict';
import test from 'node:test';
import { exportFirebase } from '../export-core.mjs';

function setup(pageToken) {
  const requested = [];
  let aborted = false;
  let finished = false;
  const auth = {
    async listUsers(maxResults, token) {
      requested.push({ maxResults, token });
      return { users: [{ uid: 'synthetic-user' }], pageToken };
    },
  };
  const firestoreApi = {
    async listCollectionIds() { return { collectionIds: [] }; },
    async listDocuments() { throw new Error('unexpected Firestore read'); },
  };
  const writer = {
    async writeJson() {},
    async finish() { finished = true; },
    async abort() { aborted = true; },
  };
  const options = {
    auth, firestoreApi, writer, project: 'demo-clrs-local',
    database: '(default)', bucketName: 'synthetic-bucket', scope: 'metadata',
    limits: {
      maxAuthUsers: 1, maxAuthListPages: 10,
      maxFirestoreCollections: 1, maxFirestoreReferences: 1,
      maxFirestoreListPages: 1,
    },
  };
  return { options, requested, get aborted() { return aborted; },
    get finished() { return finished; } };
}

test('Auth read stops at the exact user cap without requesting another page', async () => {
  const state = setup('more-users');
  await assert.rejects(exportFirebase(state.options), /Auth user limit reached/);
  assert.deepEqual(state.requested, [{ maxResults: 1, token: undefined }]);
  assert.equal(state.aborted, true);
  assert.equal(state.finished, false);
});

test('Auth read at the exact cap succeeds only when pagination is complete', async () => {
  const state = setup(undefined);
  const summary = await exportFirebase(state.options);
  assert.deepEqual(state.requested, [{ maxResults: 1, token: undefined }]);
  assert.equal(summary.authUsers, 1);
  assert.equal(state.finished, true);
  assert.equal(state.aborted, false);
});
