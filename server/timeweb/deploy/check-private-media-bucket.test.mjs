import assert from 'node:assert/strict';
import test from 'node:test';
import { checkPrivateBucket, privateBucketCheckConfig } from './check-private-media-bucket.mjs';

const syntheticEnv = {
  S3_ENDPOINT: 'https://s3.twcstorage.ru/',
  AWS_DEFAULT_REGION: 'ru-1',
  AWS_ACCESS_KEY_ID: 'synthetic-access-key',
  AWS_SECRET_ACCESS_KEY: 'synthetic-secret',
  TIMEWEB_API_TOKEN: 'synthetic-token',
};

test('private media preflight binds the exact bucket ID and uses read-only checks', async () => {
  const config = privateBucketCheckConfig(['private-backup', '17'], syntheticEnv);
  const calls = [];
  let destroyed = false;
  await checkPrivateBucket(config, {
    createClient(options) {
      assert.equal(options.endpoint, syntheticEnv.S3_ENDPOINT);
      assert.equal(options.credentials.accessKeyId, syntheticEnv.AWS_ACCESS_KEY_ID);
      return { destroy() { destroyed = true; } };
    },
    async assertPrivate(options) { calls.push(options); },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].bucket, 'private-backup');
  assert.equal(calls[0].bucketId, 17);
  assert.equal(calls[0].probe, false);
  assert.equal(destroyed, true);
});

test('privacy failure blocks copying and closes the S3 client', async () => {
  const config = privateBucketCheckConfig(['private-backup', '17'], syntheticEnv);
  let destroyed = false;
  await assert.rejects(checkPrivateBucket(config, {
    createClient() { return { destroy() { destroyed = true; } }; },
    async assertPrivate() { throw new Error('public bucket'); },
  }), /public bucket/);
  assert.equal(destroyed, true);
});

test('missing credentials, non-Timeweb endpoint and unsafe IDs fail locally', () => {
  for (const env of [
    { ...syntheticEnv, TIMEWEB_API_TOKEN: '' },
    { ...syntheticEnv, S3_ENDPOINT: 'https://elsewhere.example/' },
  ]) {
    assert.throws(() => privateBucketCheckConfig(['private-backup', '17'], env));
  }
  for (const id of ['0', '-1', '17x', '9007199254740992']) {
    assert.throws(() => privateBucketCheckConfig(['private-backup', id], syntheticEnv));
  }
});
