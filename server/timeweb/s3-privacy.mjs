import { randomBytes } from 'node:crypto';
import { DeleteObjectCommand, GetBucketAclCommand, GetBucketPolicyCommand,
  GetObjectAclCommand, PutObjectCommand } from '@aws-sdk/client-s3';

function ownerOnly(acl) {
  const ownerId = acl?.Owner?.ID;
  return typeof ownerId === 'string' && ownerId.length > 0
    && Array.isArray(acl.Grants) && acl.Grants.length === 1
    && acl.Grants[0]?.Permission === 'FULL_CONTROL'
    && acl.Grants[0]?.Grantee?.Type === 'CanonicalUser'
    && acl.Grants[0]?.Grantee?.ID === ownerId;
}

export async function assertPrivateObjectAcl(client, bucket, key) {
  const acl = await client.send(new GetObjectAclCommand({ Bucket: bucket, Key: key }));
  if (!ownerOnly(acl)) throw new Error('Private media object ACL cannot be confirmed');
}

async function confirmTimewebBucket(bucket, bucketId, token, fetchImpl) {
  if (!Number.isSafeInteger(bucketId) || bucketId < 1 || !token) {
    throw new Error('Timeweb private bucket identity is required');
  }
  const response = await fetchImpl(
    `https://api.timeweb.cloud/api/v1/storages/buckets/${bucketId}`,
    { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
      signal: AbortSignal.timeout(5000), redirect: 'error' },
  );
  if (!response.ok) throw new Error('Timeweb bucket privacy could not be confirmed');
  const data = await response.json();
  const found = data?.bucket;
  if (Number(found?.id) !== bucketId || found?.name !== bucket
      || found?.type !== 'private' || found?.website_config?.enabled === true) {
    throw new Error('Timeweb target bucket is not confirmed private');
  }
}

async function confirmS3Settings(client, bucket) {
  const acl = await client.send(new GetBucketAclCommand({ Bucket: bucket }));
  if (!ownerOnly(acl)) throw new Error('Private media bucket ACL cannot be confirmed');
  try {
    const response = await client.send(new GetBucketPolicyCommand({ Bucket: bucket }));
    // Timeweb returns an explicit empty policy after a private-type change.
    // It grants no access. Accept only that exact shape; unknown/nonempty
    // policies still block staging before any user data or probe is written.
    let policy;
    try {
      if (typeof response.Policy !== 'string' || response.Policy.length > 65536) {
        throw new Error('Invalid policy');
      }
      policy = JSON.parse(response.Policy);
    } catch {
      throw new Error('Private media bucket policy cannot be confirmed');
    }
    if (policy && policy.Version === '2012-10-17'
        && Object.keys(policy).length === 2
        && Array.isArray(policy.Statement) && policy.Statement.length === 0) return;
    // A private bucket can have a safe policy, but proving every possible
    // condition is out of scope. A dedicated migration bucket needs none.
    throw new Error('Private media bucket has an unverified policy');
  } catch (error) {
    if (error?.name !== 'NoSuchBucketPolicy') throw error;
  }
}

async function anonymousProbe(client, bucket, endpoint, fetchImpl) {
  // Keep disposable probes separate from imported user files so the
  // technical role can delete probes without delete access to any media.
  const key = `clrs-privacy-probe/${randomBytes(32).toString('hex')}`;
  const bytes = randomBytes(32); // Never send private user data as a probe.
  let attempted = false;
  try {
    attempted = true;
    await client.send(new PutObjectCommand({ Bucket: bucket, Key: key,
      Body: bytes, ContentType: 'application/octet-stream', IfNoneMatch: '*' }));
    await assertPrivateObjectAcl(client, bucket, key);
    const url = new URL(`/${bucket}/${key}`, endpoint);
    const response = await fetchImpl(url, {
      redirect: 'manual', signal: AbortSignal.timeout(5000),
      headers: { 'cache-control': 'no-store' },
    });
    // A missing object or a redirect proves nothing about access control.
    if (response.status !== 401 && response.status !== 403) {
      throw new Error('Anonymous media access was not denied');
    }
  } finally {
    // A lost PUT response does not tell us whether S3 stored the probe.
    if (attempted) await client.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
  }
}

// The Timeweb control plane exposes the bucket's actual private/public type;
// S3 ACL and policy are checked separately. Any absent/unsupported response
// blocks staging instead of trusting a CLI confirmation string.
export async function assertPrivateMediaBucket({ client, bucket, bucketId,
  timewebToken, endpoint, fetchImpl = fetch, probe = false }) {
  await confirmTimewebBucket(bucket, bucketId, timewebToken, fetchImpl);
  await confirmS3Settings(client, bucket);
  if (probe) await anonymousProbe(client, bucket, endpoint, fetchImpl);
}
