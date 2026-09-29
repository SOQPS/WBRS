import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';
import {
  createFirebaseIdTokenVerifier,
  FirebaseTokenVerificationError,
} from './firebase-id-token.mjs';

const NOW = 1_750_000_000_000;
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const certificateResponse = () => new Response(JSON.stringify({ test_key: publicKey.export({
  type: 'spki', format: 'pem',
}) }), { headers: { 'cache-control': 'public, max-age=60' } });
const validClaims = {
  aud: 'chatapp-4e347',
  iss: 'https://securetoken.google.com/chatapp-4e347',
  sub: 'synthetic-user-1',
  exp: Math.floor(NOW / 1000) + 3600,
  iat: Math.floor(NOW / 1000) - 30,
  auth_time: Math.floor(NOW / 1000) - 60,
};

function token(claims = validClaims, header = { alg: 'RS256', kid: 'test_key', typ: 'JWT' }, key = privateKey) {
  const data = `${Buffer.from(JSON.stringify(header)).toString('base64url')}.${Buffer.from(JSON.stringify(claims)).toString('base64url')}`;
  return `${data}.${sign('RSA-SHA256', Buffer.from(data), key).toString('base64url')}`;
}

function verifier(fetchImpl = async () => certificateResponse(), now = () => NOW, timeoutMs = 3000) {
  return createFirebaseIdTokenVerifier({ fetchImpl, now, timeoutMs });
}

test('accepts a valid signed Firebase ID token and exposes only stable identity fields', async () => {
  assert.deepEqual(await verifier()(token()), {
    uid: 'synthetic-user-1',
    issuedAt: validClaims.iat,
    authenticatedAt: validClaims.auth_time,
    expiresAt: validClaims.exp,
  });
});

test('rejects altered signatures and unsigned or misidentified tokens', async () => {
  const check = verifier();
  const altered = token().split('.');
  altered[1] = Buffer.from(JSON.stringify({ ...validClaims, sub: 'different-user' })).toString('base64url');
  for (const candidate of [
    altered.join('.'),
    token(validClaims, { alg: 'none', kid: 'test_key' }),
    token(validClaims, { alg: 'RS256', kid: 'unknown' }),
    'not-a-token',
  ]) {
    await assert.rejects(check(candidate), { code: 'invalid_token' });
  }
});

test('checks project, issuer, timestamps, and non-empty uid', async () => {
  const check = verifier();
  for (const patch of [
    { aud: 'other-project' },
    { iss: 'https://securetoken.google.com/other-project' },
    { exp: Math.floor(NOW / 1000) },
    { iat: Math.floor(NOW / 1000) + 1 },
    { auth_time: Math.floor(NOW / 1000) + 1 },
    { sub: '' },
  ]) {
    await assert.rejects(check(token({ ...validClaims, ...patch })), { code: 'invalid_token' });
  }
});

test('shares key fetches, honors max-age, and fails closed after timeout', async () => {
  let requests = 0;
  let clock = NOW;
  const check = verifier(async () => {
    requests += 1;
    await new Promise((resolve) => setTimeout(resolve, 5));
    return certificateResponse();
  }, () => clock);
  await Promise.all(Array.from({ length: 8 }, () => check(token())));
  assert.equal(requests, 1);
  await check(token());
  assert.equal(requests, 1);
  clock += 61_000;
  await check(token());
  assert.equal(requests, 2);

  const unavailable = verifier(async () => new Promise(() => {}), () => NOW, 10);
  await assert.rejects(unavailable(token()), (error) =>
    error instanceof FirebaseTokenVerificationError && error.code === 'keys_unavailable');
});
