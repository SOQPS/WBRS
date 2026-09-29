import assert from 'node:assert/strict';
import test from 'node:test';
import { createAuthRestAdapter } from '../auth-rest.mjs';

const credential = { async getAccessToken() { return { access_token: 'synthetic-token' }; } };

test('read-only Auth REST adapter maps paginated account metadata without password fields', async () => {
  const requests = [];
  const auth = createAuthRestAdapter({
    credential, projectId: 'demo-clrs-local',
    fetchImpl: async (url, options) => {
      requests.push({ url: String(url), options });
      return Response.json(requests.length === 1 ? {
        users: [{
          localId: 'user-1', email: 'person@example.invalid',
          emailVerified: true, disabled: false,
          createdAt: '1750000000000', lastLoginAt: '1750000001000',
          validSince: '1750000000', customAttributes: '{"admin":true}',
          providerUserInfo: [{ providerId: 'google.com', rawId: 'google-1',
            email: 'person@example.invalid' }],
          passwordHash: 'private-hash', salt: 'private-salt', version: 1,
        }], nextPageToken: 'page / two',
      } : { users: [{ localId: 'user-2' }] });
    },
  });
  const first = await auth.listUsers(1000);
  const second = await auth.listUsers(1000, first.pageToken);
  assert.equal(first.users[0].uid, 'user-1');
  assert.deepEqual(first.users[0].customClaims, { admin: true });
  assert.equal(first.users[0].providerData[0].uid, 'google-1');
  assert.equal(first.users[0].metadata.creationTime,
    new Date(1750000000000).toUTCString());
  assert.equal(first.users[0].tokensValidAfterTime,
    new Date(1750000000000).toUTCString());
  assert.equal(second.users[0].uid, 'user-2');
  assert.equal(second.pageToken, undefined);
  assert.equal(JSON.stringify(first).includes('private-hash'), false);
  assert.equal(JSON.stringify(first).includes('private-salt'), false);
  const firstUrl = new URL(requests[0].url);
  assert.equal(firstUrl.pathname,
    '/v1/projects/demo-clrs-local/accounts:batchGet');
  assert.equal(firstUrl.searchParams.get('maxResults'), '1000');
  assert.equal(new URL(requests[1].url).searchParams.get('nextPageToken'),
    'page / two');
  assert.equal(requests[0].options.method, 'GET');
  assert.equal(requests[0].options.headers.Authorization,
    'Bearer synthetic-token');
  assert.equal(requests[0].options.body, undefined);
});

test('HTTP rejection never copies server body or account data into errors', async () => {
  const auth = createAuthRestAdapter({
    credential, projectId: 'demo-clrs-local',
    fetchImpl: async () => new Response('private remote response', { status: 403 }),
  });
  await assert.rejects(auth.listUsers(1000), (error) => {
    assert.equal(error.message, 'Auth REST read failed (HTTP 403)');
    assert.equal(error.message.includes('private'), false);
    return true;
  });
});

test('ADC quota project is sent only when supplied by the credential', async () => {
  let headers;
  const auth = createAuthRestAdapter({
    credential: { ...credential, getQuotaProjectId: () => 'demo-quota-project' },
    projectId: 'demo-clrs-local',
    fetchImpl: async (_url, options) => {
      headers = options.headers;
      return Response.json({});
    },
  });
  assert.deepEqual((await auth.listUsers(1000)).users, []);
  assert.equal(headers['x-goog-user-project'], 'demo-quota-project');
});

test('invalid page, token, claims and provider records fail closed', async () => {
  const auth = createAuthRestAdapter({
    credential, projectId: 'demo-clrs-local',
    fetchImpl: async () => Response.json({ users: [{
      localId: 'user-1', customAttributes: '{bad json}',
    }] }),
  });
  await assert.rejects(auth.listUsers(1001), /Invalid Auth REST page request/);
  await assert.rejects(auth.listUsers(1000), /Invalid Auth REST claims/);
  const noToken = createAuthRestAdapter({
    credential: { async getAccessToken() { return {}; } },
    projectId: 'demo-clrs-local', fetchImpl: async () => Response.json({}),
  });
  await assert.rejects(noToken.listUsers(1000), /credential unavailable/);
});
