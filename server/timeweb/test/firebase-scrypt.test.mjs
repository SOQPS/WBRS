import assert from 'node:assert/strict';
import test from 'node:test';
import { createFirebaseScryptVerifier, firebaseScryptParameters,
  decodeCredentialBase64, assertFirebaseScryptCredential } from '../api/firebase-scrypt.mjs';

// Public fixture, not CLRS credentials. Published by Firebase at:
// https://github.com/firebase/scrypt#password-hashing
const config = {
  algorithm: 'SCRYPT',
  signerKey: 'jxspr8Ki0RYycVU8zykbdLGjFQ3McFUH0uiiTvC8pVMXAn210wjLNmdZJzxUECKbm0QsEmYUSDzZvpjeJ9WmXA==',
  saltSeparator: 'Bw==', rounds: 8, memoryCost: 14,
};
const publicRecord = {
  kind: 'auth-credential', uid: 'official-public-vector', providers: ['password'],
  passwordAccount: true, materialAvailable: true, projectAlgorithm: 'SCRYPT',
  schemeVerified: false, disabled: false, emailVerified: false, validSince: null,
  material: {
    passwordHash: 'lSrfV15cpx95/sZS2W9c9Kp6i/LVgQNDNC/qzrCnh1SAyZvqmZqAjTdn3aoItz+VHjoZilo78198JAdRuid5lQ==',
    passwordSalt: '42xEC+ixf3L2lw==', passwordVersion: 0,
  },
};

test('matches official Firebase modified-SCRYPT fixture and rejects a different password', async () => {
  const verifier = createFirebaseScryptVerifier(config);
  try {
    assert.equal(await verifier.verify(publicRecord, 'user1password'), true);
    assert.equal(await verifier.verify(publicRecord, 'incorrect-password'), false);
    assert.equal(await verifier.verify(publicRecord, ' user1password '), false);
  } finally { verifier.dispose(); }
});

test('disabled and unknown-version credentials are not allowed to log in', async () => {
  const verifier = createFirebaseScryptVerifier(config);
  try {
    assert.equal(await verifier.verify({ ...publicRecord, disabled: true }, 'user1password'), false);
    for (const version of [null, 1, '1', '00']) {
      await assert.rejects(verifier.verify({ ...publicRecord,
        material: { ...publicRecord.material, passwordVersion: version } }, 'user1password'),
      { code: 'CREDENTIAL_VERSION_UNSUPPORTED' });
    }
    assertFirebaseScryptCredential({ ...publicRecord,
      material: { ...publicRecord.material, passwordVersion: '0' } }, config);
  } finally { verifier.dispose(); }
});

test('rejects incompatible encodings and excessive memory before starting KDF', () => {
  for (const value of ['%%%=', 'AB==', 'A', 'UkVEQUNURUQ=', 'YQ===']) {
    assert.throws(() => decodeCredentialBase64(value), { code: 'ENCODING_UNSUPPORTED' });
  }
  assert.equal(decodeCredentialBase64('_w==').toString('hex'), 'ff');
  assert.throws(() => firebaseScryptParameters({ ...config, algorithm: 'STANDARD_SCRYPT' }),
    { code: 'ALGORITHM_UNSUPPORTED' });
  assert.throws(() => firebaseScryptParameters({ ...config, memoryCost: 18 }),
    { code: 'KDF_LIMIT_EXCEEDED' });
  assert.throws(() => assertFirebaseScryptCredential({ ...publicRecord,
    material: { ...publicRecord.material, passwordHash: 'YQ==' } }, config),
  { code: 'HASH_LENGTH_UNSUPPORTED' });
});

test('parallel password work is bounded and disposed verifier refuses reuse', async () => {
  const verifier = createFirebaseScryptVerifier(config, { maxInFlight: 1 });
  const first = verifier.verify(publicRecord, 'user1password');
  await assert.rejects(verifier.verify(publicRecord, 'user1password'), { code: 'KDF_BUSY' });
  assert.throws(() => verifier.dispose(), { code: 'KDF_BUSY' });
  assert.equal(await first, true);
  verifier.dispose();
  await assert.rejects(verifier.verify(publicRecord, 'user1password'), { code: 'VERIFIER_DISPOSED' });
});
