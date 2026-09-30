import test from 'node:test';
import assert from 'node:assert/strict';
import { changedClaims, parseClaims, parseEmails } from '../admin-claims.mjs';

test('grant and revoke preserve unrelated Firebase custom claims', () => {
  const original = { premium: true, role: 'author', admin: false };
  assert.deepEqual(changedClaims(original, 'grant'),
    { premium: true, role: 'author', admin: true });
  assert.deepEqual(changedClaims(original, 'revoke'),
    { premium: true, role: 'author' });
  assert.deepEqual(original, { premium: true, role: 'author', admin: false });
});

test('invalid custom claim snapshots fail closed', () => {
  assert.deepEqual(parseClaims(undefined), {});
  assert.deepEqual(parseClaims('{"premium":true}'), { premium: true });
  for (const raw of ['[]', 'null', '{', 'true']) {
    assert.throws(() => parseClaims(raw));
  }
  assert.throws(() => changedClaims({ large: 'x'.repeat(1000) }, 'grant'));
});

test('the operation requires four distinct exact email targets', () => {
  const addresses = ['a@example.com', 'b@example.com',
    'c@example.com', 'd@example.com'];
  assert.deepEqual(parseEmails(JSON.stringify(addresses)), addresses);
  assert.throws(() => parseEmails(JSON.stringify(addresses.slice(0, 3))));
  assert.throws(() => parseEmails(JSON.stringify([...addresses.slice(0, 3), addresses[0]])));
});
