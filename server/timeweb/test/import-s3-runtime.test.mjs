import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { PassThrough, Readable } from 'node:stream';
import test from 'node:test';
import { createBoundedS3Transport, createPrivateS3MediaAdapter } from '../import-adapters.mjs';
import { GetObjectAclCommand } from '@aws-sdk/client-s3';

const bytes = Buffer.from('synthetic image');
const record = { targetKey: 'synthetic-immutable-key', size: bytes.length,
  bytes, sha256: createHash('sha256').update(bytes).digest('hex'),
  metadata: { contentType: 'image/png' } };
const privateAcl = { Owner: { ID: 'owner' }, Grants: [{ Permission: 'FULL_CONTROL',
  Grantee: { Type: 'CanonicalUser', ID: 'owner' } }] };
const short = { operationTimeoutMs: 20, uploadTimeoutMs: 40,
  streamTimeoutMs: 60, streamIdleTimeoutMs: 15 };

function readingClient(body, type = 'image/png') {
  return { async send(command) {
    if (command instanceof GetObjectAclCommand) return privateAcl;
    return { Body: body, ContentType: type };
  } };
}

test('hanging S3 operation aborts once within its bounded deadline', async () => {
  let calls = 0; let aborted = false;
  const client = { send(command, options) {
    calls++; options.abortSignal.addEventListener('abort', () => { aborted = true; });
    return new Promise(() => {});
  } };
  const transport = createBoundedS3Transport(client, short);
  await assert.rejects(transport.send(new GetObjectAclCommand({ Bucket: 'synthetic', Key: record.targetKey })),
    (error) => error.code === 'CLRS_MEDIA_TIMEOUT');
  assert.equal(calls, 1); assert.equal(aborted, true);
});

test('a transport response arriving after abort has its discarded body destroyed', async () => {
  const body = new PassThrough(); let complete;
  const client = { send() { return new Promise((resolve) => { complete = resolve; }); } };
  const transport = createBoundedS3Transport(client, short);
  await assert.rejects(transport.send(new GetObjectAclCommand({ Bucket: 'synthetic' })),
    (error) => error.code === 'CLRS_MEDIA_TIMEOUT');
  complete({ Body: body });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(body.destroyed, true);
});

test('SDK automatic retry configuration is rejected before any send', async () => {
  let calls = 0;
  const client = { config: { maxAttempts: async () => 2 },
    send() { calls++; return {}; } };
  await assert.rejects(createBoundedS3Transport(client, short)
    .send(new GetObjectAclCommand({ Bucket: 'synthetic' })), /automatic retries/);
  assert.equal(calls, 0);
});

test('a hanging SDK configuration provider remains inside the operation deadline', async () => {
  let calls = 0;
  const client = { config: { maxAttempts: () => new Promise(() => {}) },
    send() { calls++; return {}; } };
  await assert.rejects(createBoundedS3Transport(client, short)
    .send(new GetObjectAclCommand({ Bucket: 'synthetic' })),
  (error) => error.code === 'CLRS_MEDIA_TIMEOUT');
  assert.equal(calls, 0);
});

test('stalled response body is destroyed on idle timeout without a PUT or progress', async () => {
  const body = new PassThrough(); let progress = 0;
  const media = createPrivateS3MediaAdapter(readingClient(body), 'synthetic',
    { ...short, onProgress: () => { progress++; } });
  await assert.rejects(media.ensure(record), (error) => error.code === 'CLRS_MEDIA_TIMEOUT');
  assert.equal(body.destroyed, true); assert.equal(progress, 0);
});

test('continued body trickle cannot extend the absolute deadline', async () => {
  const body = new PassThrough(); let sent = 0;
  const interval = setInterval(() => { sent++; body.write(Buffer.from([1])); }, 3);
  body.once('close', () => clearInterval(interval));
  const expected = Buffer.alloc(100, 1);
  const media = createPrivateS3MediaAdapter(readingClient(body), 'synthetic',
    { ...short, streamTimeoutMs: 35 });
  try {
    await assert.rejects(media.verify({ ...record, bytes: expected, size: expected.length,
      sha256: createHash('sha256').update(expected).digest('hex') }),
    (error) => error.code === 'CLRS_MEDIA_TIMEOUT');
    assert.equal(body.destroyed, true); assert.ok(sent > 1 && sent < 100);
  } finally { clearInterval(interval); body.destroy(); }
});

test('metadata mismatch closes the body and cleanup preserves the original stream error', async () => {
  const wrongType = new PassThrough();
  const media = createPrivateS3MediaAdapter(readingClient(wrongType, 'wrong/type'), 'synthetic', short);
  await assert.rejects(media.verify(record), /metadata mismatch/);
  assert.equal(wrongType.destroyed, true);
  const original = new Error('synthetic stream failure'); let cleanups = 0;
  const badBody = { async *[Symbol.asyncIterator]() { throw original; },
    destroy() { cleanups++; throw new Error('synthetic cleanup failure'); } };
  await assert.rejects(createPrivateS3MediaAdapter(readingClient(badBody), 'synthetic', short)
    .verify(record), (error) => error === original);
  assert.ok(cleanups > 0);
});

test('lost PUT acknowledgement is not retried and later exact verification reuses the object', async () => {
  let stored; let puts = 0; const ticks = [];
  const lost = new Error('synthetic lost acknowledgement');
  const client = { async send(command) {
    const kind = command.constructor.name;
    if (kind === 'PutObjectCommand') {
      assert.equal(command.input.IfNoneMatch, '*');
      puts++; stored = Buffer.from(command.input.Body); throw lost;
    }
    if (!stored) throw { name: 'NoSuchKey', $metadata: { httpStatusCode: 404 } };
    if (kind === 'GetObjectAclCommand') return privateAcl;
    return { Body: Readable.from([stored]), ContentType: 'image/png' };
  } };
  const media = createPrivateS3MediaAdapter(client, 'synthetic',
    { ...short, onProgress: (counts) => ticks.push(counts) });
  await assert.rejects(media.ensure(record), (error) => error === lost);
  assert.equal(puts, 1); assert.equal(ticks.length, 0);
  await media.ensure(record);
  assert.equal(puts, 1);
  assert.deepEqual(ticks, [{ verifiedObjects: 1, verifiedBytes: bytes.length, putAttempts: 1 }]);
});

test('timeout maxima cannot be enlarged by adapter options', () => {
  assert.throws(() => createPrivateS3MediaAdapter({}, 'synthetic',
    { streamTimeoutMs: 120001 }), /timeout/);
  assert.throws(() => createPrivateS3MediaAdapter({}, 'synthetic',
    { operationTimeoutMs: 100, streamTimeoutMs: 50 }), /ordering/);
});
