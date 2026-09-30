import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import test from 'node:test';
import { credentialRecord } from '../auth-credentials-core.mjs';
import { createFirebaseScryptVerifier } from '../api/firebase-scrypt.mjs';
import { prepareEncryptedCredentialRow, decodeEncryptedCredentialRow,
  createMySql84CredentialAdapter } from '../auth-credential-storage.mjs';

const config = {
  algorithm: 'SCRYPT',
  signerKey: 'jxspr8Ki0RYycVU8zykbdLGjFQ3McFUH0uiiTvC8pVMXAn210wjLNmdZJzxUECKbm0QsEmYUSDzZvpjeJ9WmXA==',
  saltSeparator: 'Bw==', rounds: 8, memoryCost: 14,
};
function record(uid = 'public-fixture') {
  return credentialRecord({ localId: uid, providerUserInfo: [{ providerId: 'password' }],
    passwordHash: 'lSrfV15cpx95/sZS2W9c9Kp6i/LVgQNDNC/qzrCnh1SAyZvqmZqAjTdn3aoItz+VHjoZilo78198JAdRuid5lQ==',
    salt: '42xEC+ixf3L2lw==', version: 0, validSince: '1508893925' }, 'SCRYPT');
}
function secrets() {
  return { hashConfig: config, configRef: 'public-fixture-config-v0', wrappingKey: randomBytes(32) };
}
function mysqlJson(parameters) {
  return Object.fromEntries(Object.entries(parameters).sort(([a], [b]) => a.localeCompare(b)));
}

test('ciphertext preserves UID, version type, provider/status and exact original encoding', async () => {
  const source = record('CaseSensitive-uid');
  source.material.passwordHash = source.material.passwordHash.replaceAll('/', '_').replaceAll('+', '-').replace(/=+$/, '');
  source.material.passwordVersion = '0';
  const input = secrets();
  const row = prepareEncryptedCredentialRow(source, input);
  assert.equal(row.password_hash.includes(Buffer.from(source.material.passwordHash)), false);
  assert.equal(JSON.stringify(row.parameters).includes(config.signerKey), false);
  const restored = decodeEncryptedCredentialRow({ ...row, parameters: mysqlJson(row.parameters) }, input);
  assert.deepEqual(restored, source);
  const verifier = createFirebaseScryptVerifier(config);
  try { assert.equal(await verifier.verify(restored, 'user1password'), true); }
  finally { verifier.dispose(); }
});

test('tampering, account swapping and wrong wrapping/config secrets refuse decryption', () => {
  const input = secrets();
  const row = prepareEncryptedCredentialRow(record(), input);
  for (const changed of [
    { ...row, uid: 'different-user' },
    { ...row, parameters: { ...row.parameters, disabled: true } },
    { ...row, parameters: { ...row.parameters, password_version: '0' } },
    { ...row, password_hash: Buffer.alloc(row.password_hash.length) },
  ]) assert.throws(() => decodeEncryptedCredentialRow(changed, input));
  assert.throws(() => decodeEncryptedCredentialRow(row, { ...input, wrappingKey: randomBytes(32) }));
  assert.throws(() => decodeEncryptedCredentialRow(row, { ...input,
    hashConfig: { ...config, saltSeparator: 'CA==' } }));
  assert.throws(() => prepareEncryptedCredentialRow({ ...record(),
    material: { ...record().material, passwordVersion: 2 } }, input),
  { code: 'CREDENTIAL_VERSION_UNSUPPORTED' });
});

function fakeClient({ uid = 'public-fixture', target = 'clrs_staging', disabled = 0,
  lifecycle = 'active', initial = null } = {}) {
  let retained = initial;
  const calls = [];
  return { calls,
    async query(sql) {
      calls.push({ sql });
      if (sql === 'SHOW GRANTS') return [[
        { grant: "GRANT USAGE ON *.* TO `fixture`@`%`" },
        { grant: "GRANT CREATE, INSERT, REFERENCES, SELECT, UPDATE ON `clrs_staging`.* TO `fixture`@`%`" },
      ]];
      if (sql === 'USE default_db') throw Object.assign(new Error('denied'),
        { code: 'ER_DBACCESS_DENIED_ERROR', errno: 1044 });
      if (sql.startsWith('SELECT DATABASE()')) return [[{ target, version: '8.4.8' }]];
      if (sql.includes('Ssl_cipher')) return [[{ Value: 'TLS_AES_256_GCM_SHA384' }]];
      return [[]];
    },
    async execute(sql, values = []) {
      calls.push({ sql, values });
      if (sql.includes('schema_migrations')) return [[{ version: 1 }]];
      if (sql.includes('FROM clrs_staging.accounts')) {
        return [[{ uid, disabled, email_verified: 0, lifecycle }]];
      }
      if (sql.includes('FROM clrs_staging.auth_credentials')) return [retained ? [retained] : []];
      if (sql.includes('INSERT INTO clrs_staging.auth_credentials')) {
        retained = { uid: values[0], scheme: values[1], password_hash: values[2],
          password_salt: values[3], parameters: mysqlJson(JSON.parse(values[4])) };
        return [{ affectedRows: 1 }];
      }
      throw new Error('unexpected test SQL');
    },
  };
}

test('typed adapter only stages an existing UID in the fixed target and verifies readback', async () => {
  const source = record();
  const client = fakeClient();
  const adapter = createMySql84CredentialAdapter(client, 'clrs_staging', secrets());
  await adapter.begin({ readOnly: false });
  await adapter.stage(source);
  await adapter.stage(source); // Reconcile the existing exact material; never overwrite.
  assert.deepEqual((await adapter.read(source.uid)).credential, source);
  await adapter.commit();
  const inserts = client.calls.filter(({ sql }) => sql.includes('INSERT'));
  assert.equal(inserts.length, 1);
  assert.equal(inserts[0].sql.includes('VALUES (?, ?, ?, ?, ?,'), true);
  assert.equal(client.calls.some(({ sql }) => /ALTER|DROP|CREATE TABLE|DELETE FROM|UPDATE clrs/.test(sql)), false);
});

test('current blocked/deleted/disabled account state cannot be revived by a valid old password', async () => {
  const input = secrets();
  const initial = prepareEncryptedCredentialRow(record(), input);
  for (const options of [{ disabled: 1 }, { lifecycle: 'blocked' }, { lifecycle: 'deleted' }]) {
    const adapter = createMySql84CredentialAdapter(fakeClient({ ...options, initial }), 'clrs_staging', input);
    await adapter.begin();
    try {
      assert.equal(await adapter.authenticate(record().uid, 'user1password', {
        verify() { throw new Error('KDF must not run for inactive account'); },
      }), null);
    } finally { await adapter.rollback(); }
  }
  const adapter = createMySql84CredentialAdapter(fakeClient({ initial }), 'clrs_staging', input);
  const verifier = createFirebaseScryptVerifier(config);
  await adapter.begin();
  try {
    assert.deepEqual(await adapter.authenticate(record().uid, 'user1password', verifier),
      { uid: record().uid, emailVerified: false });
    assert.equal(await adapter.authenticate(record().uid, 'wrong', verifier), null);
  } finally { await adapter.rollback(); verifier.dispose(); }
});

test('read-only mode, mismatched source account status or wrong database prevent inserts', async () => {
  for (const options of [{ readOnly: true }, { disabled: 1 }, { target: 'default_db' }, { uid: 'different-user' }]) {
    const client = fakeClient(options);
    const adapter = createMySql84CredentialAdapter(client, 'clrs_staging', secrets());
    try {
      if (options.target) await assert.rejects(adapter.begin({ readOnly: false }));
      else {
        await adapter.begin({ readOnly: options.readOnly ?? false });
        await assert.rejects(adapter.stage(record()));
      }
      assert.equal(client.calls.some(({ sql }) => sql.includes('INSERT')), false);
    } finally { await adapter.rollback(); }
  }
  assert.throws(() => createMySql84CredentialAdapter(fakeClient(), 'default_db', secrets()));
});
