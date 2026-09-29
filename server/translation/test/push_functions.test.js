import assert from 'node:assert/strict';
import test from 'node:test';

test('new social triggers use installed Functions SDK with bounded resources and no translation secrets', async () => {
  process.env.GCLOUD_PROJECT = 'demo-clrs-push-events';
  process.env.CLRS_PUSH_ENABLED = 'false';
  const exports = await import('../src/index.js');
  for (const [name, document] of [
    ['notifyFriendRequest', 'users/{recipientUid}/friend_requests/{actorUid}'],
    ['notifyFriendAccepted', 'users/{recipientUid}/friends/{actorUid}'],
    ['notifyRegionalMeeting', 'meets/{entityId}'],
  ]) {
    const fn = exports[name], endpoint = fn.__endpoint;
    assert.equal(typeof fn, 'function', name);
    assert.equal(endpoint.platform, 'gcfv2', name);
    assert.equal(endpoint.minInstances, 0, name);
    assert.equal(endpoint.maxInstances, 2, name);
    assert.equal(endpoint.timeoutSeconds, 120, name);
    assert.equal(endpoint.eventTrigger.eventFilterPathPatterns.document, document, name);
    assert.deepEqual(endpoint.secretEnvironmentVariables || [], [], name);
    // Disabled events return before reading Admin SDK data or sending FCM.
    await fn.run({ params: {}, data: { get createTime() { throw new Error('unexpected source read'); } } });
  }
});
