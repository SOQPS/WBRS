import assert from 'node:assert/strict';
import test from 'node:test';
import { assertPrivateMediaBucket, assertPrivateObjectAcl } from '../s3-privacy.mjs';

const privateAcl = {
  Owner: { ID: 'owner-id' },
  Grants: [{ Permission: 'FULL_CONTROL',
    Grantee: { Type: 'CanonicalUser', ID: 'owner-id' } }],
};
const publicAcl = {
  ...privateAcl,
  Grants: [...privateAcl.Grants, { Permission: 'READ',
    Grantee: { Type: 'Group', URI: 'http://acs.amazonaws.com/groups/global/AllUsers' } }],
};

function fakePrivacy({ type = 'private', acl = privateAcl,
  policy = false, anonymousStatus = 403, unsupported = false,
  uncertainPut = false } = {}) {
  const calls = { s3: [], anonymous: 0, deleted: 0 };
  const client = {
    async send(command) {
      const name = command.constructor.name;
      calls.s3.push(name);
      if (unsupported) throw new Error('S3 privacy API unsupported');
      if (name === 'GetBucketAclCommand' || name === 'GetObjectAclCommand') return acl;
      if (name === 'GetBucketPolicyCommand') {
        if (policy) return { Policy: policy };
        throw { name: 'NoSuchBucketPolicy', $metadata: { httpStatusCode: 404 } };
      }
      if (name === 'PutObjectCommand') {
        assert.equal(command.input.IfNoneMatch, '*');
        assert.match(command.input.Key, /^clrs-privacy-probe\/[a-f0-9]{64}$/);
        if (uncertainPut) throw new Error('PUT response lost');
        return {};
      }
      if (name === 'DeleteObjectCommand') {
        assert.match(command.input.Key, /^clrs-privacy-probe\/[a-f0-9]{64}$/);
        calls.deleted++;
        return {};
      }
      throw new Error('Unexpected S3 request');
    },
  };
  const fetchImpl = async (url, options) => {
    if (String(url).startsWith('https://api.timeweb.cloud/')) {
      assert.equal(options.headers.Authorization, 'Bearer synthetic-token');
      return Response.json({ bucket: { id: 17, name: 'private-clrs', type } });
    }
    calls.anonymous++;
    assert.match(String(url), /^https:\/\/s3\.twcstorage\.ru\/private-clrs\/clrs-privacy-probe\/[a-f0-9]{64}$/);
    assert.equal(options.headers['cache-control'], 'no-store');
    return new Response('', { status: anonymousStatus });
  };
  return { calls, client, fetchImpl };
}

function options(fake, probe = true) {
  return { client: fake.client, fetchImpl: fake.fetchImpl, probe,
    bucket: 'private-clrs', bucketId: 17, timewebToken: 'synthetic-token',
    endpoint: 'https://s3.twcstorage.ru/' };
}

test('private control-plane type, owner ACL, absent policy and anonymous denial permit stage', async () => {
  const fake = fakePrivacy();
  await assertPrivateMediaBucket(options(fake));
  assert.equal(fake.calls.anonymous, 1);
  assert.equal(fake.calls.deleted, 1);
});

test('public Timeweb bucket type is rejected before any S3 upload', async () => {
  const fake = fakePrivacy({ type: 'public' });
  await assert.rejects(assertPrivateMediaBucket(options(fake)), /not confirmed private/);
  assert.deepEqual(fake.calls.s3, []);
});

test('public bucket ACL or nonempty bucket policy blocks staging', async () => {
  const openAcl = fakePrivacy({ acl: publicAcl });
  await assert.rejects(assertPrivateMediaBucket(options(openAcl)), /ACL/);
  assert.equal(openAcl.calls.s3.includes('PutObjectCommand'), false);
  const openPolicy = fakePrivacy({ policy: JSON.stringify({Version:'2012-10-17',
    Statement:[{Effect:'Allow',Principal:'*',Action:'s3:GetObject',Resource:'*'}]}) });
  await assert.rejects(assertPrivateMediaBucket(options(openPolicy)), /unverified policy/);
  assert.equal(openPolicy.calls.s3.includes('PutObjectCommand'), false);
});

test('Timeweb explicit empty policy grants no access and permits privacy probe', async () => {
  const fake = fakePrivacy({policy:'{"Version":"2012-10-17","Statement":[]}'});
  await assertPrivateMediaBucket(options(fake));
  assert.equal(fake.calls.anonymous,1);
  assert.equal(fake.calls.deleted,1);
});

test('malformed or unexpected empty policy blocks before upload', async () => {
  for (const policy of ['not json','{"Statement":[]}',
    '{"Version":"2012-10-17","Statement":[],"Unknown":true}']) {
    const fake = fakePrivacy({policy});
    await assert.rejects(assertPrivateMediaBucket(options(fake)), /policy/);
    assert.equal(fake.calls.s3.includes('PutObjectCommand'),false);
  }
});

test('unsupported privacy API fails closed without uploading', async () => {
  const fake = fakePrivacy({ unsupported: true });
  await assert.rejects(assertPrivateMediaBucket(options(fake)), /unsupported/);
  assert.equal(fake.calls.s3.includes('PutObjectCommand'), false);
});

test('anonymous read of a probe blocks staging and removes the harmless probe', async () => {
  const fake = fakePrivacy({ anonymousStatus: 200 });
  await assert.rejects(assertPrivateMediaBucket(options(fake)), /Anonymous media access/);
  assert.equal(fake.calls.deleted, 1);
});

test('probe deletion is attempted even when the PUT result is uncertain', async () => {
  const fake = fakePrivacy({ uncertainPut: true });
  await assert.rejects(assertPrivateMediaBucket(options(fake)), /PUT response lost/);
  assert.equal(fake.calls.deleted, 1);
});

test('an existing object with public ACL is not accepted on retry', async () => {
  const fake = fakePrivacy({ acl: publicAcl });
  await assert.rejects(assertPrivateObjectAcl(fake.client, 'private-clrs', 'clrs-import-quarantine/key'),
    /object ACL/);
});
