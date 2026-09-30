#!/usr/bin/env node
// Read-only preflight for a bucket that will receive private user media.
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { S3Client } from '@aws-sdk/client-s3';
import { assertPrivateMediaBucket } from '../s3-privacy.mjs';

export function privateBucketCheckConfig(args, env = process.env) {
  const [bucket, rawId] = args;
  if (args.length !== 2
      || !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket ?? '')
      || !/^[1-9][0-9]*$/.test(rawId ?? '')
      || !Number.isSafeInteger(Number(rawId))
      || env.S3_ENDPOINT !== 'https://s3.twcstorage.ru/'
      || !env.AWS_DEFAULT_REGION || !env.AWS_ACCESS_KEY_ID
      || !env.AWS_SECRET_ACCESS_KEY || !env.TIMEWEB_API_TOKEN) {
    throw new Error('Private Timeweb media bucket configuration is incomplete');
  }
  return {
    bucket, bucketId: Number(rawId), endpoint: env.S3_ENDPOINT,
    region: env.AWS_DEFAULT_REGION,
    accessKeyId: env.AWS_ACCESS_KEY_ID,
    secretAccessKey: env.AWS_SECRET_ACCESS_KEY,
    timewebToken: env.TIMEWEB_API_TOKEN,
  };
}

export async function checkPrivateBucket(config, {
  createClient = (options) => new S3Client(options),
  assertPrivate = assertPrivateMediaBucket,
} = {}) {
  const client = createClient({
    endpoint: config.endpoint, region: config.region, forcePathStyle: true,
    credentials: {
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
    },
  });
  try {
    await assertPrivate({
      client, bucket: config.bucket, bucketId: config.bucketId,
      timewebToken: config.timewebToken, endpoint: config.endpoint,
      probe: false,
    });
  } finally {
    client.destroy();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await checkPrivateBucket(privateBucketCheckConfig(process.argv.slice(2)));
  } catch {
    // Provider exceptions may contain tokens, bucket names or request details.
    process.stderr.write('Private Timeweb media bucket could not be verified.\n');
    process.exitCode = 1;
  }
}
