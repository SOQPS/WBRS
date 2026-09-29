import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

test('real Firebase Functions SDK exports deployable Node22 handler without network', async () => {
  process.env.GCLOUD_PROJECT = 'demo-clrs-local';
  process.env.TRANSLATION_ENABLED = 'false';
  const { translateContent } = await import('../src/index.js');
  assert.equal(typeof translateContent, 'function');
  assert.equal(translateContent.__endpoint.platform, 'gcfv2');
  assert.equal(translateContent.__endpoint.timeoutSeconds, 20);
  assert.equal(translateContent.__endpoint.maxInstances, 2);
  assert.equal(translateContent.__endpoint.minInstances, 0);
});

test('Google fallback export binds only the cache secret and does not inherit AWS secrets', async () => {
  process.env.GCLOUD_PROJECT = 'demo-clrs-local';
  process.env.GOOGLE_TRANSLATION_ENABLED = 'false';
  const { translateContent, translateContentGoogle } = await import('../src/index.js');
  assert.equal(typeof translateContentGoogle, 'function');
  const endpoint = translateContentGoogle.__endpoint;
  assert.equal(endpoint.platform, 'gcfv2');
  assert.equal(endpoint.timeoutSeconds, 20);
  assert.equal(endpoint.minInstances, 0);
  assert.equal(endpoint.maxInstances, 2);
  assert.deepEqual(endpoint.secretEnvironmentVariables.map(secret => secret.key), ['TRANSLATION_CACHE_HMAC_KEY']);
  assert.deepEqual(translateContent.__endpoint.secretEnvironmentVariables.map(secret => secret.key),
    ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'TRANSLATION_CACHE_HMAC_KEY']);
});

test('targeted uuid override preserves gaxios6 CommonJS v4 API', () => {
  const require = createRequire(import.meta.url);
  const gaxiosRequire = createRequire(require.resolve('gaxios'));
  const uuid = gaxiosRequire('uuid');
  assert.match(uuid.v4(), /^[a-f\d]{8}-[a-f\d]{4}-4[a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/);
  assert.equal(typeof require('gaxios').request, 'function');
});

test('trusted push exports use the installed Functions SDK without network or secrets', async () => {
  process.env.GCLOUD_PROJECT = 'demo-clrs-local';
  process.env.CLRS_PUSH_ENABLED = 'false';
  const exports = await import('../src/index.js');
  for (const name of ['requestPush', 'pushPrivateMessage', 'pushMeetingMessage',
    'notifyPostComment', 'notifyPostLike', 'notifyCommentLike']) {
    assert.equal(typeof exports[name], 'function', name);
    const endpoint = exports[name].__endpoint;
    assert.equal(endpoint.platform, 'gcfv2', name);
    assert.equal(endpoint.minInstances, 0, name);
    assert.equal(endpoint.maxInstances, 2, name);
    assert.equal(endpoint.timeoutSeconds, name === 'requestPush' ? 20 : 120, name);
    assert.deepEqual(endpoint.secretEnvironmentVariables || [], [], name);
  }
});
