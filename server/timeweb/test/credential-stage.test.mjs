import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { appendFile, chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { credentialRecord } from '../auth-credentials-core.mjs';
import { prepareEncryptedCredentialRow } from '../auth-credential-storage.mjs';
import { collectArchiveManifest } from '../manifest-from-archive.mjs';
import { payloadHash } from '../import-core.mjs';
import { CREDENTIAL_STAGE_LIMITS, prepareCredentialStage, credentialStageSummary,
  disposeCredentialStage, stageCredentials, verifyStagedCredentials,
  credentialInsertBatches } from '../credential-stage-core.mjs';
import { mainCredentialStage, parseCredentialStageArgs, readCredentialStageReceipt,
  writeCredentialStageReceipt } from '../credential-stage-cli.mjs';

// Firebase's public SCRYPT vector, never a production user or secret.
const hashConfig = { algorithm: 'SCRYPT',
  signerKey: 'jxspr8Ki0RYycVU8zykbdLGjFQ3McFUH0uiiTvC8pVMXAn210wjLNmdZJzxUECKbm0QsEmYUSDzZvpjeJ9WmXA==',
  saltSeparator: 'Bw==', rounds: 8, memoryCost: 14 };
const publicHash = 'lSrfV15cpx95/sZS2W9c9Kp6i/LVgQNDNC/qzrCnh1SAyZvqmZqAjTdn3aoItz+VHjoZilo78198JAdRuid5lQ==';
const publicSalt = '42xEC+ixf3L2lw==';
const source = { kind: 'source', format: 2, project: 'clrs-synthetic', database: '(default)',
  bucket: 'clrs-synthetic.appspot.com', scope: 'all', storagePrefix: '',
  completeSource: true, passwordHashesIncluded: false, snapshotConsistent: false };
const expectedSource = { project: source.project, database: source.database, bucket: source.bucket };
const sha = (value) => createHash('sha256').update(value).digest('hex');
const stageTime = '2026-10-01 01:02:03.123456';
const publicUid = "synthetic-'u1";
const clone = (value) => Buffer.isBuffer(value) ? Buffer.from(value) : Array.isArray(value)
  ? value.map(clone) : value && typeof value === 'object'
    ? Object.fromEntries(Object.entries(value).map(([key, part]) => [key, clone(part)])) : value;

function users() {
  return [
    { uid: publicUid, email: 'user1@example.invalid', disabled: false, emailVerified: true,
      providerData: [{ providerId: 'password', uid: 'user1@example.invalid', email: 'user1@example.invalid' }],
      tokensValidAfterTime: new Date(1508893925 * 1000).toUTCString() },
    { uid: 'synthetic-u2', email: 'user2@example.invalid', disabled: true, emailVerified: false,
      providerData: [{ providerId: 'password', uid: 'user2@example.invalid', email: 'user2@example.invalid' }],
      tokensValidAfterTime: new Date(1508893925 * 1000).toUTCString() },
  ];
}
function credentials(auth) {
  return auth.map((user) => credentialRecord({ localId: user.uid,
    disabled: user.disabled, emailVerified: user.emailVerified,
    providerUserInfo: [{ providerId: 'password' }], passwordHash: publicHash,
    salt: publicSalt, version: 0, validSince: '1508893925' }, 'SCRYPT'));
}
function documents(auth) {
  return auth.map((user, index) => ({ kind: 'firestore-document', path: `users/${user.uid}`,
    fields: { uid: { stringValue: user.uid }, status: { stringValue: index ? 'blocked' : 'active' },
      fullName: { stringValue: `Synthetic ${index}` } },
    createTime: '2026-06-01T00:00:00Z', updateTime: '2026-09-30T00:00:00Z' }));
}
async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-credential-stage-'));
  await chmod(directory, 0o700);
  t.after(() => rm(directory, { recursive: true, force: true }));
  const key = randomBytes(32); const credentialKey = randomBytes(32);
  const hmacKey = randomBytes(32); const wrappingKey = randomBytes(32);
  const auth = options.auth ?? users(); const docs = options.docs ?? documents(auth);
  const records = options.credentials ?? credentials(auth);
  const archivePath = join(directory, 'full.clrsenc');
  const writer = await EncryptedArchiveWriter.create(archivePath, key);
  await writer.writeJson({ ...source, ...options.source });
  for (const user of auth) await writer.writeJson({ kind: 'auth-user', user });
  for (const document of docs) await writer.writeJson(document);
  const object = Buffer.from('a public synthetic image');
  await writer.writeJson({ kind: 'storage-object', name: 'synthetic.jpg',
    metadata: { size: String(object.length), generation: '1' } });
  await writer.writeBytes(object);
  await writer.writeJson({ kind: 'storage-sha256', name: 'synthetic.jpg', sha256: sha(object) });
  await writer.finish({ authUsers: auth.length, authListPages: 1,
    firestoreDocuments: docs.length, firestoreMissingParents: 0, firestoreReferences: docs.length,
    firestoreCollections: 1, firestoreListPages: 1, storageObjects: 1, storageBytes: object.length,
    storageListPages: 1 });
  const manifest = options.manifest ?? (await collectArchiveManifest({ archivePath, archiveKey: key, hmacKey })).manifest;
  const credentialArchivePath = join(directory, 'credentials.clrsenc');
  const credentialWriter = await EncryptedArchiveWriter.create(credentialArchivePath, credentialKey);
  await credentialWriter.writeJson({ kind: 'auth-credential-source', format: 1,
    project: options.credentialProject ?? expectedSource.project,
    scope: 'auth-credentials-only', completeSource: true, standaloneLoginVerified: false });
  await credentialWriter.writeJson({ kind: 'auth-hash-config', hashConfig: options.hashConfig ?? hashConfig });
  for (const record of records) await credentialWriter.writeJson(record);
  const versions = {};
  for (const record of records) versions[String(record.material.passwordVersion)] = (versions[String(record.material.passwordVersion)] ?? 0) + 1;
  await credentialWriter.finish({ authUsers: records.length, passwordAccounts: records.length,
    materialAvailable: records.length, unavailablePasswordAccounts: 0, nonPasswordAccounts: 0,
    hashVersions: versions, projectAlgorithm: (options.hashConfig ?? hashConfig).algorithm, standaloneLoginVerified: false });
  return { archivePath, key, credentialArchivePath, credentialKey, hmacKey, wrappingKey,
    manifest, expectedSource, configRef: 'synthetic-scrypt-v0', directory, auth, docs, records };
}
async function planFor(t, options) {
  const input = await fixture(t, options);
  const plan = await prepareCredentialStage(input);
  t.after(() => disposeCredentialStage(plan));
  return { input, plan };
}
function confirmations(plan) {
  return { targetDatabase: 'clrs_staging', archiveSha256: plan.archiveSha256,
    credentialArchiveSha256: plan.credentialArchiveSha256, planSha256: plan.planSha256 };
}

// Transaction-aware mysql2 double. All values remain in memory and no network
// access is possible. It deliberately canonicalizes MySQL JSON property order.
function fakeClient(input, options = {}) {
  const authRows = input.auth.map((user) => ({ uid: user.uid,
    encoded_payload: JSON.stringify(user), payload_hash: payloadHash(user).toUpperCase() }));
  const rootRows = input.docs.map((doc) => { const data = { fields: doc.fields, createTime: doc.createTime, updateTime: doc.updateTime };
    return { firebase_path: doc.path, encoded_payload: JSON.stringify(data), payload_hash: payloadHash(data).toUpperCase() }; });
  const accounts = input.auth.map((user, index) => ({ uid: user.uid, email_normalized: user.email.trim().toLowerCase(),
    disabled: Number(user.disabled), email_verified: Number(user.emailVerified), lifecycle: index ? 'blocked' : 'active', token_version: 0 }));
  const identities = input.auth.flatMap((user) => user.providerData.map((provider) => ({ uid: user.uid,
    provider: provider.providerId, provider_subject: provider.uid, provider_email: provider.email,
    legacy_raw: JSON.stringify(provider) })));
  let committed = clone(options.initial ?? []); let working; let readOnly;
  const calls = [];
  return { calls, authRows, rootRows, accounts, identities,
    get data() { return clone(committed); },
    async query(sql) {
      calls.push({ sql });
      if (sql === 'SHOW GRANTS') return [[
        { grant: 'GRANT USAGE ON *.* TO `synthetic`@`%`' },
        { grant: `GRANT CREATE, INSERT, REFERENCES, SELECT, UPDATE${options.extraGrant ? ', DELETE' : ''} ON \`clrs_staging\`.* TO \`synthetic\`@\`%\`` },
      ]];
      if (sql === 'USE default_db') {
        if (options.legacyAllowed) return [[]];
        throw Object.assign(new Error('Synthetic denial'), { errno: 1044, code: 'ER_DBACCESS_DENIED_ERROR' });
      }
      if (sql.includes('Ssl_cipher')) return [[{ Value: options.noTls ? '' : 'TLS_AES_256_GCM_SHA384' }]];
      if (sql.startsWith('SET ')) return [[]];
      if (sql.startsWith('START TRANSACTION')) {
        assert.equal(working, undefined); working = clone(committed); readOnly = sql.includes('READ ONLY'); return [[]];
      }
      if (sql === 'COMMIT') {
        assert.ok(working);
        if (options.commitLostBeforeApply) { options.commitLostBeforeApply = false; throw new Error('Lost before apply'); }
        if (!readOnly) committed = working;
        working = undefined;
        if (options.commitLostAfterApply) { options.commitLostAfterApply = false; throw new Error('Lost after apply'); }
        return [[]];
      }
      if (sql === 'ROLLBACK') { working = undefined; return [[]]; }
      throw new Error('Unexpected synthetic SQL query');
    },
    async execute(sql, params = []) {
      calls.push({ sql, params });
      if (sql.includes('SELECT DATABASE()')) return [[{ target_database: options.database ?? 'clrs_staging',
        mysql_version: options.version ?? '8.4.6', page_size: 16384, sql_mode: 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION',
        charset: 'utf8mb4', max_allowed_packet: options.packet ?? 64 * 1024 * 1024 }]];
      if (sql.includes('schema_migrations')) return [[{ version: 1 }]];
      if (sql.includes('information_schema.tables')) return [Array.from({ length: 42 }, (_, index) => ({
        name: `synthetic_${index}`, engine: 'InnoDB', collation: 'utf8mb4_0900_bin', format: 'Dynamic' }))];
      if (sql.includes('referential_constraints')) return [[{ total: 66 }]];
      assert.ok(working, 'Source/credential data stays inside one transaction');
      if (sql.includes('FROM clrs_staging.legacy_source')) return [[{
        source_project: options.sourceProject ?? source.project, source_database: source.database, source_bucket: source.bucket }]];
      if (sql.includes('AS auth_users')) return [[{ auth_users: authRows.length, root_profiles: rootRows.length,
        accounts: accounts.length, identities: identities.length }]];
      if (sql.includes('FROM clrs_staging.legacy_auth_users')) return [authRows.filter((row) => params.includes(sha(row.uid)))];
      if (sql.includes('FROM clrs_staging.legacy_documents')) return [rootRows.filter((row) => params.includes(sha(row.firebase_path)))];
      if (sql.includes('FROM clrs_staging.accounts')) return [accounts.filter((row) => params.includes(row.uid))];
      if (sql.includes('FROM clrs_staging.auth_identities')) return [identities.filter((row) => params.includes(row.uid))];
      if (sql.startsWith('SELECT COUNT(*) AS total')) return [[{ total: working.length }]];
      if (sql.includes('FROM clrs_staging.auth_credentials')) return [clone(working.filter((row) => params.includes(row.uid)))];
      if (sql.includes('AS stage_time')) return [[{ stage_time: stageTime }]];
      if (sql.startsWith('INSERT INTO clrs_staging.auth_credentials')) {
        assert.equal(readOnly, false);
        assert.equal(params.length % 6, 0);
        for (let offset = 0; offset < params.length; offset += 6) {
          assert.equal(working.some((row) => row.uid === params[offset]), false);
          working.push({ uid: params[offset], scheme: params[offset + 1],
            password_hash: Buffer.from(params[offset + 2]), password_salt: Buffer.from(params[offset + 3]),
            parameters: Object.fromEntries(Object.entries(JSON.parse(params[offset + 4])).sort(([a], [b]) => a.localeCompare(b))),
            imported_at: params[offset + 5] });
          if (options.failInsert) throw new Error('Synthetic interrupted batch');
        }
        if (options.tamperReadback) working[0].password_hash[30] ^= 1;
        return [{ affectedRows: params.length / 6 }];
      }
      throw new Error('Unexpected synthetic SQL execute');
    },
  };
}

test('full archive + FINAL manifest bind exact UIDs and preserve encrypted SCRYPT material', async (t) => {
  const { input, plan } = await planFor(t);
  assert.deepEqual(plan.counts, { authUsers: 2, credentials: 2, identities: 2, rootProfiles: 2,
    disabledAccounts: 1, blockedAccounts: 1, deletedAccounts: 0 });
  const summary = JSON.stringify(credentialStageSummary(plan));
  for (const privateValue of [publicUid, publicHash, publicSalt, hashConfig.signerKey, 'user1@example.invalid']) {
    assert.equal(summary.includes(privateValue), false);
  }
  assert.equal(JSON.parse(summary).standaloneLoginVerified, false);
  const second = await prepareCredentialStage(input);
  t.after(() => disposeCredentialStage(second));
  assert.equal(plan.planSha256, second.planSha256, 'Random AES nonces do not change source plan identity');
  assert.throws(() => { plan.planSha256 = 'changed'; }, TypeError);
});

test('partial/tampered/trailing credential or full archives cannot create a stage plan', async (t) => {
  for (const field of ['archivePath', 'credentialArchivePath']) {
    for (const mode of ['truncate', 'tamper', 'trailing']) {
      const input = await fixture(t); const bytes = await readFile(input[field]);
      if (mode === 'truncate') await writeFile(input[field], bytes.subarray(0, bytes.length - 12));
      if (mode === 'tamper') { bytes[bytes.length - 1] ^= 1; await writeFile(input[field], bytes); }
      if (mode === 'trailing') await appendFile(input[field], Buffer.from([0]));
      await assert.rejects(prepareCredentialStage(input));
    }
  }
  const client = { query() { throw new Error('Invalid plan must not query SQL'); } };
  await assert.rejects(stageCredentials(client, {}, {}, async () => {}), /authenticated/);
});

test('same counts with different UIDs, source, HMAC inventory or account state fail closed', async (t) => {
  const changed = credentials(users()); changed[1].uid = 'same-count-foreign-uid';
  await assert.rejects(prepareCredentialStage(await fixture(t, { credentials: changed })), /UID sets/);
  await assert.rejects(prepareCredentialStage(await fixture(t, { credentialProject: 'wrong-source-project' })), /source mismatch/);
  const input = await fixture(t);
  const wrongManifest = clone(input.manifest); wrongManifest.auth.users[0].uid = 'a'.repeat(64);
  await assert.rejects(prepareCredentialStage({ ...input, manifest: wrongManifest }), /FINAL inventory/);
  await assert.rejects(prepareCredentialStage({ ...input, hmacKey: randomBytes(32) }), /FINAL inventory/);
  await assert.rejects(prepareCredentialStage({ ...input, expectedSource: { ...expectedSource, database: 'foreign-database' } }), /source mismatch/);
  for (const field of ['disabled', 'providers', 'validSince']) {
    const records = credentials(users());
    if (field === 'disabled') records[0].disabled = true;
    if (field === 'providers') records[0].providers = ['password', 'google.com'];
    if (field === 'validSince') records[0].validSince = '1508893926';
    await assert.rejects(prepareCredentialStage(await fixture(t, { credentials: records })), /disagree|revocation state/);
  }
});

test('unsupported SCRYPT version, raw password shape and reviewed source caps are refused', async (t) => {
  const version = credentials(users()); version[0].material.passwordVersion = 1;
  await assert.rejects(prepareCredentialStage(await fixture(t, { credentials: version })), { code: 'CREDENTIAL_VERSION_UNSUPPORTED' });
  const auth = users(); auth[0].passwordHash = publicHash;
  await assert.rejects(fixture(t, { auth }), /Auth UID/);
  const input = await fixture(t);
  await assert.rejects(prepareCredentialStage({ ...input, limits: { maxAuthUsers: 1 } }), /caps/);
  await assert.rejects(prepareCredentialStage({ ...input, limits: { maxAuthUsers: CREDENTIAL_STAGE_LIMITS.maxAuthUsers + 1 } }), /reviewed bound/);
  await assert.rejects(prepareCredentialStage({ ...input, limits: { notReviewed: 10 } }));
  await assert.rejects(prepareCredentialStage({ ...input, wrappingKey: input.key }), /Separate/);
});

test('stage parameterizes encrypted batches and validates readback before its durable receipt/COMMIT', async (t) => {
  const { input, plan } = await planFor(t); const client = fakeClient(input); let receipt;
  const result = await stageCredentials(client, plan, confirmations(plan), async (record) => {
    assert.equal(client.data.length, 0, 'COMMIT has not happened when the receipt is persisted');
    receipt = record;
  });
  assert.equal(result.insertedCredentials, 2); assert.equal(result.databaseCommitted, true);
  assert.equal(result.standaloneLoginVerified, false);
  const insert = client.calls.find(({ sql }) => sql.startsWith('INSERT'));
  assert.equal(insert.sql.includes(publicUid), false);
  assert.equal(insert.params.filter(Buffer.isBuffer).length, 4);
  for (const row of client.data) {
    assert.equal(row.password_hash.includes(Buffer.from(publicHash)), false);
    assert.equal(row.password_salt.includes(Buffer.from(publicSalt)), false);
    assert.equal(JSON.stringify(row.parameters).includes(hashConfig.signerKey), false);
  }
  assert.equal(client.calls.some(({ sql }) => /DELETE|UPDATE clrs|ALTER|DROP|GRANT |CREATE TABLE/.test(sql)), false);
  const verify = await verifyStagedCredentials(client, plan, 'clrs_staging', receipt);
  assert.deepEqual(verify, { mode: 'verify', state: 'present_verified', credentialRowsVerified: 2,
    planSha256: plan.planSha256, databaseWrites: 0, standaloneLoginVerified: false });
});

test('exact existing credentials are idempotent; a conflicting row is never overwritten', async (t) => {
  const { input, plan } = await planFor(t); const client = fakeClient(input);
  await stageCredentials(client, plan, confirmations(plan), async () => {});
  const before = client.data;
  const repeated = await stageCredentials(client, plan, confirmations(plan), async () => {});
  assert.equal(repeated.insertedCredentials, 0); assert.equal(repeated.retainedCredentials, 2);
  assert.deepEqual(client.data, before);
  const conflicting = clone(before); conflicting[0].password_salt[30] ^= 1;
  const broken = fakeClient(input, { initial: conflicting });
  await assert.rejects(stageCredentials(broken, plan, confirmations(plan), async () => {}));
  assert.equal(broken.calls.some(({ sql }) => sql.startsWith('INSERT')), false);
  const partial = fakeClient(input, { initial: before.slice(0, 1) });
  const resumed = await stageCredentials(partial, plan, confirmations(plan), async () => {});
  assert.equal(resumed.insertedCredentials, 1); assert.equal(resumed.retainedCredentials, 1);
  assert.deepEqual(partial.data[0], before[0]);
});

test('wrong target/grants/default_db access/TLS/packet stop before INSERT', async (t) => {
  const { input, plan } = await planFor(t);
  for (const options of [{ database: 'default_db' }, { version: '8.0.40' }, { extraGrant: true },
    { legacyAllowed: true }, { noTls: true }, { packet: 1024 }]) {
    const client = fakeClient(input, options);
    await assert.rejects(stageCredentials(client, plan, confirmations(plan), async () => {}));
    assert.equal(client.calls.some(({ sql }) => sql.startsWith('INSERT')), false);
  }
  const client = fakeClient(input);
  await assert.rejects(stageCredentials(client, plan, { ...confirmations(plan), planSha256: 'a'.repeat(64) }, async () => {}));
  assert.equal(client.calls.length, 0);
});

test('foreign raw Auth/profile/account/identity links abort before credential inserts', async (t) => {
  const { input, plan } = await planFor(t);
  for (const kind of ['raw-auth', 'raw-profile', 'account-status', 'account-uid', 'identity', 'source']) {
    const client = fakeClient(input, kind === 'source' ? { sourceProject: 'foreign-project' } : {});
    if (kind === 'raw-auth') client.authRows[0].encoded_payload = JSON.stringify({ uid: 'foreign-uid' });
    if (kind === 'raw-profile') client.rootRows[0].encoded_payload = JSON.stringify({ fields: { status: { stringValue: 'active' } } });
    if (kind === 'account-status') client.accounts[1].lifecycle = 'active';
    if (kind === 'account-uid') client.accounts[0].uid = 'foreign-uid';
    if (kind === 'identity') client.identities[0].provider_subject = 'foreign-provider-subject';
    await assert.rejects(stageCredentials(client, plan, confirmations(plan), async () => {}));
    assert.equal(client.calls.some(({ sql }) => sql.startsWith('INSERT')), false);
    assert.equal(client.data.length, 0);
  }
});

test('batch/readback/receipt failures roll back the entire stage', async (t) => {
  const { input, plan } = await planFor(t);
  for (const kind of ['insert', 'readback', 'receipt']) {
    const client = fakeClient(input, { failInsert: kind === 'insert', tamperReadback: kind === 'readback' });
    await assert.rejects(stageCredentials(client, plan, confirmations(plan), async () => {
      if (kind === 'receipt') throw new Error('Synthetic disk failure');
    }));
    assert.equal(client.data.length, 0);
    assert.equal(client.calls.some(({ sql }) => sql === 'COMMIT'), false);
    assert.equal(client.calls.some(({ sql }) => sql === 'ROLLBACK'), true);
  }
});

test('lost COMMIT reply is reconciled from the receipt, never treated as an ordinary retry', async (t) => {
  const { input, plan } = await planFor(t);
  for (const applied of [true, false]) {
    const client = fakeClient(input, applied ? { commitLostAfterApply: true } : { commitLostBeforeApply: true });
    let receipt;
    await assert.rejects(stageCredentials(client, plan, confirmations(plan), async (record) => { receipt = record; }),
    { code: 'CREDENTIAL_STAGE_COMMIT_UNKNOWN' });
    const result = await verifyStagedCredentials(client, plan, 'clrs_staging', receipt);
    assert.equal(result.state, applied ? 'present_verified' : 'not_committed_verified');
    assert.equal(result.credentialRowsVerified, applied ? 2 : 0);
  }
});

test('receipt binds wrapping/config/source identity and exact ciphertext readback', async (t) => {
  const { input, plan } = await planFor(t); const client = fakeClient(input); let receipt;
  await stageCredentials(client, plan, confirmations(plan), async (record) => { receipt = record; });
  for (const field of ['planSha256', 'archiveSha256', 'wrappingKeyId', 'configIdentity', 'configRef']) {
    await assert.rejects(verifyStagedCredentials(client, plan, 'clrs_staging', { ...receipt, [field]: 'wrong' }), /Receipt/);
  }
  const encrypted = clone(client.data);
  // Re-encrypting the same secret is semantically equal but no longer the
  // ciphertext described by the durable possibly-committed receipt.
  Object.assign(encrypted[0], prepareEncryptedCredentialRow(input.records[0], {
    hashConfig, configRef: input.configRef, wrappingKey: input.wrappingKey }));
  await assert.rejects(verifyStagedCredentials(fakeClient(input, { initial: encrypted }), plan, 'clrs_staging', receipt), /reconciled/);
  const file = join(input.directory, 'receipt.clrsenc');
  await writeCredentialStageReceipt(file, input.credentialKey, receipt);
  assert.deepEqual(await readCredentialStageReceipt(file, input.credentialKey), receipt);
  assert.equal((await readFile(file)).includes(Buffer.from('clrs-credential-stage-receipt')), false);
  await assert.rejects(writeCredentialStageReceipt(file, input.credentialKey, receipt), { code: 'EEXIST' });
});

test('batches honor 100-row and actual UTF-8/binary packet bounds', () => {
  const row = prepareEncryptedCredentialRow(credentials(users())[0], {
    hashConfig, configRef: 'synthetic-scrypt-v0', wrappingKey: randomBytes(32) });
  const records = Array.from({ length: 205 }, (_, i) => ({ ...row, uid: `synthetic-${i}` }));
  assert.deepEqual([...credentialInsertBatches(records, 32 * 1024 * 1024)].map((batch) => batch.length), [100, 100, 5]);
  const wide = { ...row, uid: 'Ю'.repeat(191) };
  assert.throws(() => [...credentialInsertBatches([wide], 600)], /packet budget/);
});

test('receipt row ordering is byte-exact UTF-8 for case and non-ASCII UIDs', async (t) => {
  const auth = ['ä', 'Z', 'a', 'A', 'ß'].map((uid, index) => ({ ...users()[0], uid,
    email: `synthetic${index}@example.invalid`, providerData: [{ providerId: 'password',
      uid: `synthetic${index}@example.invalid`, email: `synthetic${index}@example.invalid` }] }));
  const { input, plan } = await planFor(t, { auth });
  const client = fakeClient(input); let receipt;
  await stageCredentials(client, plan, confirmations(plan), async (record) => { receipt = record; });
  const expected = payloadHash(client.data.sort((a, b) => Buffer.compare(Buffer.from(a.uid), Buffer.from(b.uid))).map((row) => ({
    uid: row.uid, scheme: row.scheme, password_hash: row.password_hash.toString('hex'),
    password_salt: row.password_salt.toString('hex'), parameters: row.parameters, imported_at: row.imported_at,
  })));
  assert.equal(receipt.targetRowsSha256, expected);
});

test('CLI dry-run uses only completed private files; limits/modes/confirmation are strict', async (t) => {
  const input = await fixture(t);
  const paths = { '--archive': input.archivePath, '--credentials': input.credentialArchivePath };
  for (const [option, data] of [['--key-file', input.key], ['--credentials-key-file', input.credentialKey],
    ['--hmac-key-file', input.hmacKey], ['--wrapping-key-file', input.wrappingKey],
    ['--manifest', JSON.stringify(input.manifest)]]) {
    const file = join(input.directory, option.slice(2)); await writeFile(file, data, { mode: 0o600 }); paths[option] = file;
  }
  const args = Object.entries({ ...paths, '--config-ref': input.configRef,
    '--project': source.project, '--database': source.database, '--bucket': source.bucket }).flat();
  const dry = await mainCredentialStage(args);
  assert.equal(dry.completeFullArchiveVerified, true); assert.equal(dry.databaseWrites, 0);
  assert.equal(dry.counts.credentials, 2);
  assert.throws(() => parseCredentialStageArgs([...args, '--mode', 'rollback']), /mode/);
  assert.throws(() => parseCredentialStageArgs([...args, '--mode', 'stage']), /authenticated hashes/);
  assert.throws(() => parseCredentialStageArgs([...args, '--max-auth-users', '10001']), /reviewed bound/);
  assert.throws(() => parseCredentialStageArgs([...args, '--mode', 'dry-run', '--mode', 'dry-run']), /arguments/);
  await chmod(paths['--wrapping-key-file'], 0o644);
  await assert.rejects(mainCredentialStage(args), /private regular file/);
});
