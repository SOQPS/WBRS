import assert from 'node:assert/strict';
import test from 'node:test';
import { firestoreApi } from '../export-firebase-encrypted.mjs';

test('Firestore export forwards the ADC quota project on both read operations', async () => {
  const calls = [];
  const credential = {
    async getAccessToken() { return { access_token: 'synthetic-token' }; },
    getQuotaProjectId() { return 'demo-quota-project'; },
  };
  const fetchImpl = async (url, options) => {
    calls.push({ url: String(url), options });
    return Response.json({ collectionIds: [], documents: [] });
  };
  const api = firestoreApi(credential, 'demo-clrs-local', '(default)', fetchImpl);

  await api.listCollectionIds('profiles/a');
  await api.listDocuments('profiles');

  assert.equal(calls.length, 2);
  for (const { options } of calls) {
    assert.equal(options.headers['x-goog-user-project'], 'demo-quota-project');
    assert.equal(options.headers.Authorization, 'Bearer synthetic-token');
    assert.ok(options.signal instanceof AbortSignal);
  }
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[1].options.method, 'GET');
});

test('Firestore export rejects an invalid quota project before a request', async () => {
  let requested = false;
  const credential = {
    async getAccessToken() { return { access_token: 'synthetic-token' }; },
    getQuotaProjectId() { return 'invalid/project'; },
  };
  const api = firestoreApi(credential, 'demo-clrs-local', '(default)', () => {
    requested = true;
    throw new Error('unexpected request');
  });
  await assert.rejects(api.listCollectionIds(''), /Invalid Firestore quota project/);
  assert.equal(requested, false);
});
