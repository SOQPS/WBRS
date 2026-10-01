import { createHash } from 'node:crypto';
import { stat } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { readEncryptedArchive } from './encrypted-archive.mjs';
import { credentialRecord, validateHashConfig } from './auth-credentials-core.mjs';
import { prepareEncryptedCredentialRow, decodeEncryptedCredentialRow } from './auth-credential-storage.mjs';
import { collectArchiveManifest } from './manifest-from-archive.mjs';
import { validateManifest } from './manifest.mjs';
import { payloadHash, scanImportArchive } from './import-core.mjs';
import { assertMigrationGrants } from './mysql84-schema-core.mjs';

const DATABASE = 'clrs_staging';
const privatePlans = new WeakMap();
const SHA = /^[0-9a-f]{64}$/;
const BATCH = 100;
const MAX_METADATA_BYTES = 256 * 1024 * 1024;
export const CREDENTIAL_STAGE_LIMITS = Object.freeze({ maxAuthUsers: 10000,
  maxFirestoreDocuments: 100000, maxStorageObjects: 10000,
  maxStorageBytes: 7200000000, maxObjectBytes: 64000000 });
const fail = (message = 'Credential stage validation failed') => { throw new Error(message); };
const object = (value) => value && typeof value === 'object' && !Array.isArray(value);
const hash = (value) => createHash('sha256').update(value).digest('hex');
const json = (value) => typeof value === 'string' || Buffer.isBuffer(value)
  ? JSON.parse(value.toString('utf8')) : value;
const count = (value) => {
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result < 0) fail();
  return result;
};
const batches = function* (records) {
  for (let index = 0; index < records.length; index += BATCH) yield records.slice(index, index + BATCH);
};
function text(value, limit, optional = false) {
  if (optional && (value === undefined || value === null)) return null;
  if (typeof value !== 'string' || (!optional && !value)
      || [...value].length > limit || value.includes('\0')) fail();
  return value;
}
function material(plan) {
  const result = privatePlans.get(plan);
  if (!result) fail('A complete authenticated credential plan is required');
  return result;
}
function limits(input = {}) {
  if (!object(input) || Object.keys(input).some((key) => !(key in CREDENTIAL_STAGE_LIMITS))) fail();
  const result = { ...CREDENTIAL_STAGE_LIMITS, ...input };
  for (const [key, value] of Object.entries(result)) {
    if (!Number.isSafeInteger(value) || value < 1 || value > CREDENTIAL_STAGE_LIMITS[key]) {
      fail('Credential stage limit cannot exceed the reviewed bound');
    }
  }
  return result;
}

async function scanCredentials({ credentialArchivePath, credentialKey, project, maxUsers }) {
  const info = await stat(credentialArchivePath);
  // The live bundle is about 3.6 MB. Refuse arbitrarily large credential files
  // independently of the bounded archive frame and user count.
  if (!info.isFile() || info.size > 20 * 1024 * 1024) fail('Credential bundle exceeds the reviewed bound');
  const cipherHash = createHash('sha256');
  const records = [];
  const seen = new Set();
  let section = 'source'; let config; let source;
  const summary = { authUsers: 0, passwordAccounts: 0, materialAvailable: 0,
    unavailablePasswordAccounts: 0, nonPasswordAccounts: 0, hashVersions: {},
    projectAlgorithm: null, standaloneLoginVerified: false };
  for await (const frame of readEncryptedArchive(credentialArchivePath, credentialKey, {
    onCiphertext: (bytes) => cipherHash.update(bytes),
  })) {
    if (frame.type !== 'json' || !object(frame.record)) fail('Unexpected credential bundle frame');
    const record = frame.record;
    if (section === 'source') {
      if (record.kind !== 'auth-credential-source' || record.format !== 1
          || record.scope !== 'auth-credentials-only' || record.completeSource !== true
          || record.project !== project || record.standaloneLoginVerified !== false) {
        fail('Credential bundle source mismatch');
      }
      source = record; section = 'config';
    } else if (section === 'config') {
      if (record.kind !== 'auth-hash-config') fail();
      config = validateHashConfig(record.hashConfig);
      summary.projectAlgorithm = config.algorithm; section = 'users';
    } else if (section === 'users' && record.kind === 'auth-credential') {
      if (records.length >= maxUsers || seen.has(record.uid)) fail('Credential UID limit or duplicate');
      const rebuilt = credentialRecord({ localId: record.uid,
        providerUserInfo: record.providers?.map((providerId) => ({ providerId })),
        passwordHash: record.material?.passwordHash ?? undefined,
        salt: record.material?.passwordSalt ?? undefined,
        version: record.material?.passwordVersion ?? undefined,
        disabled: record.disabled, emailVerified: record.emailVerified,
        validSince: record.validSince }, config.algorithm);
      if (!isDeepStrictEqual(record, rebuilt)) fail('Credential bundle record mismatch');
      text(record.uid, 191); seen.add(record.uid); records.push(record);
      summary.authUsers++;
      if (record.passwordAccount) {
        summary.passwordAccounts++;
        if (record.materialAvailable) summary.materialAvailable++;
        else summary.unavailablePasswordAccounts++;
        const version = record.material.passwordVersion === null ? 'unknown' : String(record.material.passwordVersion);
        summary.hashVersions[version] = (summary.hashVersions[version] ?? 0) + 1;
      } else summary.nonPasswordAccounts++;
    } else if (section === 'users' && record.kind === 'end') {
      if (!isDeepStrictEqual(record.summary, summary)) fail('Credential bundle completion mismatch');
      section = 'complete';
    } else fail('Unexpected credential bundle order');
  }
  if (section !== 'complete' || !source || !records.length) fail('Incomplete or empty credential bundle');
  return { records, config, summary, credentialArchiveSha256: cipherHash.digest('hex') };
}

function lifecycle(document, uid) {
  if (!document) return 'active';
  const fields = document.encodedPayload.fields;
  if (Object.hasOwn(fields, 'uid')) {
    const value = fields.uid;
    if (!object(value) || Object.keys(value).length !== 1
        || !(Object.hasOwn(value, 'nullValue') || value.stringValue === uid)) fail('Root profile UID mismatch');
  }
  const status = fields.status;
  if (status === undefined || Object.hasOwn(status ?? {}, 'nullValue')) return 'active';
  if (!object(status) || Object.keys(status).length !== 1
      || !['active', 'blocked', 'deleted'].includes(status.stringValue)) fail('Unsupported source lifecycle');
  return status.stringValue;
}

function accountAndIdentities(record, document) {
  const user = record.encodedPayload;
  const uid = text(user.uid, 191);
  if (user.tenantId !== undefined && user.tenantId !== null && user.tenantId !== '') fail('Tenant identities need a separate mapping');
  if (typeof user.disabled !== 'boolean' || typeof user.emailVerified !== 'boolean'
      || !Array.isArray(user.providerData ?? [])) fail();
  const email = text(user.email, 320, true);
  const identities = (user.providerData ?? []).map((provider) => {
    if (!object(provider)) fail();
    return { uid, provider: text(provider.providerId, 191),
      provider_subject: text(provider.uid, 191),
      provider_email: text(provider.email, 320, true), legacy_raw: provider };
  });
  return { account: { uid, email_normalized: email === null || !email.trim() ? null : email.trim().toLowerCase(),
    email_verified: Number(user.emailVerified), disabled: Number(user.disabled),
    lifecycle: lifecycle(document, uid), token_version: 0 }, identities };
}

function sameAuthState(user, credential) {
  if (user.disabled !== credential.disabled || user.emailVerified !== credential.emailVerified
      || !isDeepStrictEqual((user.providerData ?? []).map((entry) => entry.providerId).sort(),
        [...credential.providers].sort())) fail('Credential and full Auth snapshot disagree');
  const sourceTime = user.tokensValidAfterTime;
  if (sourceTime !== undefined && sourceTime !== null) {
    const seconds = Number(credential.validSince);
    if (credential.validSince === null || !Number.isSafeInteger(seconds) || seconds < 0
        || !Number.isSafeInteger(seconds * 1000) || Date.parse(sourceTime) !== seconds * 1000) {
      fail('Credential revocation state changed between snapshots');
    }
  } else if (credential.validSince !== null && Number(credential.validSince) !== 0) {
    fail('Credential revocation state is missing from the full Auth snapshot');
  }
}

// Only a full end-authenticated archive and its exact FINAL schema-v2 inventory
// authorize a plan. Metadata exports/UID caches cannot reach the SQL functions.
// Storage is streamed once; at most one guarded object is buffered by the reader.
export async function prepareCredentialStage(inputs) {
  const cap = limits(inputs.limits);
  const expected = inputs.expectedSource;
  if (!object(expected) || !['project', 'database', 'bucket'].every((name) =>
    typeof expected[name] === 'string' && expected[name] && [...expected[name]].length <= 191)) fail();
  if (!Buffer.isBuffer(inputs.wrappingKey) || inputs.wrappingKey.length !== 32
      || !/^[A-Za-z0-9_-]{1,128}$/.test(inputs.configRef ?? '')) fail();
  if ([inputs.key, inputs.credentialKey, inputs.hmacKey].some((key) =>
    !Buffer.isBuffer(key) || key.length !== 32 || inputs.wrappingKey.equals(key))) fail('Separate 32-byte wrapping/export keys required');
  if (inputs.manifest?.auth?.count > cap.maxAuthUsers
      || inputs.manifest?.firestore?.count > cap.maxFirestoreDocuments
      || inputs.manifest?.storage?.count > cap.maxStorageObjects
      || inputs.manifest?.storage?.bytes > cap.maxStorageBytes) fail('FINAL inventory exceeds reviewed source caps');
  validateManifest(inputs.manifest);
  const authRecords = []; const rootDocuments = [];
  let metadataBytes = 0;
  function accountMetadata(value) {
    metadataBytes += Buffer.byteLength(JSON.stringify(value), 'utf8');
    if (metadataBytes > MAX_METADATA_BYTES) fail('Decoded metadata exceeds the reviewed memory bound');
  }
  let scanned;
  const rebuilt = await collectArchiveManifest({ archivePath: inputs.archivePath,
    archiveKey: inputs.key, hmacKey: inputs.hmacKey, limits: cap,
    scanArchive: async (options) => {
      scanned = await scanImportArchive({ ...options,
        onAuth: async (record) => { accountMetadata(record.encodedPayload); authRecords.push(record); await options.onAuth(record); },
        onDocument: async (record) => {
          accountMetadata(record.encodedPayload);
          if (/^users\/[^/]+$/.test(record.firebasePath)) rootDocuments.push(record);
          await options.onDocument(record);
        },
        onObject: async (record) => { accountMetadata(record.metadata); await options.onObject(record); },
      });
      return scanned;
    },
  });
  if (!isDeepStrictEqual(rebuilt.manifest, inputs.manifest)) fail('FINAL inventory does not match the complete archive');
  if (!['project', 'database', 'bucket'].every((name) => scanned.source[name] === expected[name])) {
    fail('Full archive source mismatch');
  }
  const bundle = await scanCredentials({ ...inputs, project: expected.project, maxUsers: cap.maxAuthUsers });
  if (bundle.records.length !== authRecords.length) fail('Credential/full Auth UID sets differ');
  const credentialByUid = new Map(bundle.records.map((record) => [record.uid, record]));
  const roots = new Map(rootDocuments.map((record) => [record.documentId, record]));
  const secrets = { hashConfig: bundle.config, configRef: inputs.configRef,
    wrappingKey: Buffer.from(inputs.wrappingKey) };
  const accounts = []; const identities = []; const preparedRows = [];
  const normalizedEmails = new Set(); const subjects = new Set();
  try {
    for (const auth of authRecords) {
      const credential = credentialByUid.get(auth.uid);
      if (!credential) fail('Credential/full Auth UID sets differ');
      sameAuthState(auth.encodedPayload, credential);
      const projected = accountAndIdentities(auth, roots.get(auth.uid));
      if (projected.account.email_normalized !== null) {
        if (normalizedEmails.has(projected.account.email_normalized)) fail('Duplicate normalized email');
        normalizedEmails.add(projected.account.email_normalized);
      }
      for (const identity of projected.identities) {
        const id = JSON.stringify([identity.provider, identity.provider_subject]);
        if (subjects.has(id)) fail('Duplicate provider identity');
        subjects.add(id);
      }
      // Unsupported/non-password versions are never silently substituted with
      // a different scheme; the existing password-capable CLRS batch is SCRYPT0.
      const row = prepareEncryptedCredentialRow(credential, secrets);
      if (!isDeepStrictEqual(decodeEncryptedCredentialRow(row, secrets), credential)) fail();
      preparedRows.push(row); accounts.push(projected.account); identities.push(...projected.identities);
    }
    const counts = Object.freeze({ authUsers: authRecords.length, credentials: preparedRows.length,
      identities: identities.length, rootProfiles: rootDocuments.length,
      disabledAccounts: accounts.filter((row) => row.disabled === 1).length,
      blockedAccounts: accounts.filter((row) => row.lifecycle === 'blocked').length,
      deletedAccounts: accounts.filter((row) => row.lifecycle === 'deleted').length });
    const binding = { archiveSha256: scanned.archiveSha256,
      credentialArchiveSha256: bundle.credentialArchiveSha256,
      finalManifestSha256: payloadHash(inputs.manifest),
      wrappingKeyId: hash(secrets.wrappingKey), configRef: inputs.configRef,
      configIdentity: preparedRows[0].parameters.config_identity, counts };
    const plan = Object.freeze({ ...binding, planSha256: payloadHash(binding), counts });
    privatePlans.set(plan, { source: scanned.source, authRecords, rootDocuments,
      accounts, identities, credentials: bundle.records, preparedRows, secrets });
    return plan;
  } catch (error) { secrets.wrappingKey.fill(0); throw error; }
}

export function credentialStageSummary(plan) {
  material(plan);
  return { mode: 'dry-run', ...plan, completeFullArchiveVerified: true,
    finalInventoryVerified: true, exactAuthUidSetVerified: true, encryptedRowRoundtripVerified: true,
    databaseWrites: 0, firebaseReads: 0, standaloneLoginVerified: false };
}
export function disposeCredentialStage(plan) {
  const retained = privatePlans.get(plan);
  if (retained) {
    retained.secrets.wrappingKey.fill(0);
    for (const row of retained.preparedRows) { row.password_hash.fill(0); row.password_salt.fill(0); }
    privatePlans.delete(plan);
  }
}

async function rows(client, sql, params = []) {
  const [result] = await client.execute(sql, params);
  if (!Array.isArray(result)) fail();
  return result;
}
async function preflight(client, write) {
  if (write) {
    const [grants] = await client.query('SHOW GRANTS');
    assertMigrationGrants(grants);
    let denied = false;
    try { await client.query('USE default_db'); }
    catch (error) { if (error?.errno === 1044 && error?.code === 'ER_DBACCESS_DENIED_ERROR') denied = true; else fail(); }
    if (!denied) fail('Legacy database must be inaccessible');
  }
  await client.query("SET SESSION time_zone = '+00:00'");
  await client.query("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'");
  const server = await rows(client, `SELECT DATABASE() AS target_database, VERSION() AS mysql_version,
    @@innodb_page_size AS page_size, @@session.sql_mode AS sql_mode,
    @@character_set_connection AS charset, @@max_allowed_packet AS max_allowed_packet`);
  const current = server[0];
  if (server.length !== 1 || current.target_database !== DATABASE || !/^8\.4\./.test(current.mysql_version ?? '')
      || Number(current.page_size) !== 16384 || current.charset !== 'utf8mb4'
      || !/(^|,)STRICT_TRANS_TABLES(,|$)/.test(current.sql_mode ?? '')
      || count(current.max_allowed_packet) < 1024) fail('Strict MySQL 8.4 staging target required');
  const [tls] = await client.query("SHOW SESSION STATUS LIKE 'Ssl_cipher'");
  if (!Array.isArray(tls) || tls.length !== 1 || !tls[0].Value) fail('Database TLS required');
  const migrations = await rows(client, 'SELECT version FROM clrs_staging.schema_migrations ORDER BY version');
  const tables = await rows(client, `SELECT table_name AS name, engine AS engine,
    table_collation AS collation, row_format AS format FROM information_schema.tables WHERE table_schema = ?`, [DATABASE]);
  const constraints = await rows(client,
    'SELECT COUNT(*) AS total FROM information_schema.referential_constraints WHERE constraint_schema = ?', [DATABASE]);
  if (migrations.length !== 1 || Number(migrations[0].version) !== 1 || tables.length !== 42
      || tables.some((row) => row.engine !== 'InnoDB' || row.collation !== 'utf8mb4_0900_bin' || row.format !== 'Dynamic')
      || constraints.length !== 1 || count(constraints[0].total) !== 66) fail('Reviewed schema 42 tables/66 foreign keys required');
  return Math.floor(count(current.max_allowed_packet) / 2);
}

async function sourcePreflight(client, plan, lock) {
  const data = material(plan); const suffix = lock ? ' FOR UPDATE' : '';
  const source = await rows(client, `SELECT source_project, source_database, source_bucket
    FROM clrs_staging.legacy_source WHERE singleton = 1${suffix}`);
  if (source.length !== 1 || source[0].source_project !== data.source.project
      || source[0].source_database !== data.source.database || source[0].source_bucket !== data.source.bucket) fail('Staged legacy source mismatch');
  const totals = await rows(client, `SELECT
    (SELECT COUNT(*) FROM clrs_staging.legacy_auth_users) AS auth_users,
    (SELECT COUNT(*) FROM clrs_staging.legacy_documents WHERE collection_path_sha256 = UNHEX(?) AND collection_path = ?) AS root_profiles,
    (SELECT COUNT(*) FROM clrs_staging.accounts) AS accounts,
    (SELECT COUNT(*) FROM clrs_staging.auth_identities) AS identities`, [hash('users'), 'users']);
  if (totals.length !== 1 || count(totals[0].auth_users) !== plan.counts.authUsers
      || count(totals[0].root_profiles) !== plan.counts.rootProfiles
      || count(totals[0].accounts) !== plan.counts.authUsers
      || count(totals[0].identities) !== plan.counts.identities) fail('Legacy/profile projection counts mismatch');
  for (const [table, field, index, records] of [
    ['legacy_auth_users', 'uid', 'uid_sha256', data.authRecords],
    ['legacy_documents', 'firebase_path', 'firebase_path_sha256', data.rootDocuments],
  ]) {
    for (const batch of batches(records)) {
      const ids = batch.map((record) => field === 'uid' ? record.uid : record.firebasePath);
      const found = await rows(client, `SELECT ${field}, encoded_payload, HEX(payload_sha256) AS payload_hash
        FROM clrs_staging.${table} WHERE ${index} IN (${batch.map(() => 'UNHEX(?)').join(', ')})${suffix}`, ids.map(hash));
      const byId = new Map(found.map((row) => [row[field], row]));
      if (found.length !== batch.length || byId.size !== batch.length || batch.some((record, i) => {
        const row = byId.get(ids[i]);
        return !row || row.payload_hash?.toLowerCase() !== record.sha256
          || payloadHash(json(row.encoded_payload)) !== record.sha256
          || !isDeepStrictEqual(json(row.encoded_payload), record.encodedPayload);
      })) fail('Staged raw source does not match the authenticated archive');
    }
  }
  for (const batch of batches(data.accounts)) {
    const found = await rows(client, `SELECT uid, email_normalized, email_verified, disabled, lifecycle, token_version
      FROM clrs_staging.accounts WHERE uid IN (${batch.map(() => '?').join(', ')})${suffix}`, batch.map((row) => row.uid));
    const byUid = new Map(found.map((row) => [row.uid, row]));
    if (found.length !== batch.length || byUid.size !== batch.length || batch.some((expected) => {
      const row = byUid.get(expected.uid);
      return !row || row.email_normalized !== expected.email_normalized || row.lifecycle !== expected.lifecycle
        || count(row.email_verified) !== expected.email_verified || count(row.disabled) !== expected.disabled
        || count(row.token_version) !== expected.token_version;
    })) fail('Account projection changed; credentials cannot reactivate or reassign an account');
    const identities = await rows(client, `SELECT uid, provider, provider_subject, provider_email, legacy_raw
      FROM clrs_staging.auth_identities WHERE uid IN (${batch.map(() => '?').join(', ')})${suffix}`, batch.map((row) => row.uid));
    const expected = data.identities.filter((row) => byUid.has(row.uid));
    const key = (row) => JSON.stringify([row.uid, row.provider, row.provider_subject]);
    const byId = new Map(identities.map((row) => [key(row), row]));
    if (identities.length !== expected.length || byId.size !== expected.length || expected.some((row) => {
      const stored = byId.get(key(row));
      return !stored || stored.provider_email !== row.provider_email || !isDeepStrictEqual(json(stored.legacy_raw), row.legacy_raw);
    })) fail('Identity projection mismatch');
  }
}

async function retainedRows(client, plan, lock) {
  const data = material(plan); const retained = [];
  const total = await rows(client, 'SELECT COUNT(*) AS total FROM clrs_staging.auth_credentials');
  if (total.length !== 1 || count(total[0].total) > plan.counts.credentials) fail('Unexpected credential rows');
  const expected = new Map(data.credentials.map((record) => [record.uid, record]));
  for (const batch of batches(data.accounts)) {
    const found = await rows(client, `SELECT uid, scheme, password_hash, password_salt, parameters,
      DATE_FORMAT(imported_at, '%Y-%m-%d %H:%i:%s.%f') AS imported_at
      FROM clrs_staging.auth_credentials WHERE uid IN (${batch.map(() => '?').join(', ')})${lock ? ' FOR UPDATE' : ''}`,
    batch.map((row) => row.uid));
    for (const row of found) {
      const restored = decodeEncryptedCredentialRow(row, data.secrets);
      if (!isDeepStrictEqual(restored, expected.get(row.uid))
          || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}$/.test(row.imported_at ?? '')) {
        fail('Existing credential conflicts; never overwrite it');
      }
      retained.push(row);
    }
  }
  if (retained.length !== count(total[0].total) || new Set(retained.map((row) => row.uid)).size !== retained.length) {
    fail('Credential UID set mismatch');
  }
  return retained;
}
function rowDigest(records) {
  return payloadHash([...records].sort((a, b) => Buffer.compare(Buffer.from(a.uid, 'utf8'), Buffer.from(b.uid, 'utf8'))).map((row) => ({
    uid: row.uid, scheme: row.scheme, password_hash: row.password_hash.toString('hex'),
    password_salt: row.password_salt.toString('hex'), parameters: json(row.parameters), imported_at: row.imported_at,
  })));
}
export function* credentialInsertBatches(records, packetBudget) {
  if (!Number.isSafeInteger(packetBudget) || packetBudget < 512) fail();
  let batch = []; let size = 512;
  for (const row of records) {
    const bytes = 160 + Buffer.byteLength(row.uid, 'utf8') + Buffer.byteLength(row.scheme, 'utf8')
      + row.password_hash.length + row.password_salt.length + Buffer.byteLength(JSON.stringify(row.parameters), 'utf8');
    if (bytes + 512 > packetBudget) fail('Credential row exceeds the guarded packet budget');
    if (batch.length && (batch.length === BATCH || size + bytes > packetBudget)) {
      yield batch; batch = []; size = 512;
    }
    batch.push(row); size += bytes;
  }
  if (batch.length) yield batch;
}
function confirmations(plan, values) {
  material(plan);
  if (values?.targetDatabase !== DATABASE || values.archiveSha256 !== plan.archiveSha256
      || values.credentialArchiveSha256 !== plan.credentialArchiveSha256 || values.planSha256 !== plan.planSha256) {
    fail('Explicit database and all authenticated source confirmations are required');
  }
}
export function checkCredentialStageReceipt(plan, receipt) {
  material(plan);
  if (!receipt || receipt.kind !== 'clrs-credential-stage-receipt' || receipt.version !== 1
      || receipt.state !== 'prepared' || receipt.targetDatabase !== DATABASE
      || receipt.planSha256 !== plan.planSha256 || receipt.archiveSha256 !== plan.archiveSha256
      || receipt.credentialArchiveSha256 !== plan.credentialArchiveSha256
      || receipt.finalManifestSha256 !== plan.finalManifestSha256 || receipt.wrappingKeyId !== plan.wrappingKeyId
      || receipt.configRef !== plan.configRef || receipt.configIdentity !== plan.configIdentity
      || !SHA.test(receipt.beforeRowsSha256 ?? '') || !SHA.test(receipt.targetRowsSha256 ?? '')
      || !Number.isSafeInteger(receipt.beforeCount) || receipt.beforeCount < 0 || receipt.beforeCount > plan.counts.credentials
      || receipt.targetCount !== plan.counts.credentials || receipt.insertedCount !== receipt.targetCount - receipt.beforeCount) fail('Receipt does not match the authenticated credential plan');
}
async function begin(client, readOnly) {
  await client.query(`SET TRANSACTION ISOLATION LEVEL ${readOnly ? 'REPEATABLE READ' : 'SERIALIZABLE'}`);
  await client.query(`START TRANSACTION${readOnly ? ' READ ONLY' : ''}`);
}

export async function stageCredentials(client, plan, values, persistReceipt) {
  confirmations(plan, values);
  if (typeof persistReceipt !== 'function') fail('Durable encrypted receipt required');
  const packetBudget = await preflight(client, true);
  const data = material(plan);
  // Validate the entire prepared batch before the first INSERT, not just the
  // subset still missing from an exact previously committed stage.
  for (const ignored of credentialInsertBatches(data.preparedRows, packetBudget)) void ignored;
  let opened = false; let commitAttempted = false;
  try {
    await begin(client, false); opened = true;
    await sourcePreflight(client, plan, true);
    const before = await retainedRows(client, plan, true);
    const present = new Set(before.map((row) => row.uid));
    const pending = data.preparedRows.filter((row) => !present.has(row.uid));
    const time = await rows(client, "SELECT DATE_FORMAT(UTC_TIMESTAMP(6), '%Y-%m-%d %H:%i:%s.%f') AS stage_time");
    if (time.length !== 1 || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}$/.test(time[0].stage_time ?? '')) fail();
    for (const batch of credentialInsertBatches(pending, packetBudget)) {
      const [result] = await client.execute(`INSERT INTO clrs_staging.auth_credentials
        (uid, scheme, password_hash, password_salt, parameters, imported_at) VALUES ${batch.map(() => '(?, ?, ?, ?, ?, ?)').join(', ')}`,
      batch.flatMap((row) => [row.uid, row.scheme, row.password_hash, row.password_salt, JSON.stringify(row.parameters), time[0].stage_time]));
      if (result.affectedRows !== batch.length) fail('Credential insert count mismatch');
    }
    const after = await retainedRows(client, plan, true);
    if (after.length !== plan.counts.credentials) fail('Credential readback count mismatch');
    const receipt = { kind: 'clrs-credential-stage-receipt', version: 1, state: 'prepared', targetDatabase: DATABASE,
      planSha256: plan.planSha256, archiveSha256: plan.archiveSha256,
      credentialArchiveSha256: plan.credentialArchiveSha256, finalManifestSha256: plan.finalManifestSha256,
      wrappingKeyId: plan.wrappingKeyId, configRef: plan.configRef, configIdentity: plan.configIdentity,
      beforeCount: before.length, beforeRowsSha256: rowDigest(before), targetCount: after.length,
      targetRowsSha256: rowDigest(after), insertedCount: pending.length };
    checkCredentialStageReceipt(plan, receipt);
    await persistReceipt(receipt);
    commitAttempted = true;
    await client.query('COMMIT'); opened = false;
    return { mode: 'stage', state: 'present_verified', databaseCommitted: true,
      insertedCredentials: pending.length, retainedCredentials: before.length,
      credentialRowsVerified: after.length, planSha256: plan.planSha256, standaloneLoginVerified: false };
  } catch (error) {
    if (opened) await client.query('ROLLBACK').catch(() => {});
    if (commitAttempted) {
      const unknown = new Error('Credential COMMIT outcome unknown; use receipt-bound verify before any retry');
      unknown.code = 'CREDENTIAL_STAGE_COMMIT_UNKNOWN'; throw unknown;
    }
    throw error;
  }
}

export async function verifyStagedCredentials(client, plan, targetDatabase, receipt) {
  material(plan);
  if (targetDatabase !== DATABASE) fail('Explicit staging target confirmation required');
  if (receipt) checkCredentialStageReceipt(plan, receipt);
  await preflight(client, false);
  let opened = false;
  try {
    await begin(client, true); opened = true;
    await sourcePreflight(client, plan, false);
    const retained = await retainedRows(client, plan, false);
    const digest = rowDigest(retained);
    let state;
    if (retained.length === plan.counts.credentials && (!receipt || digest === receipt.targetRowsSha256)) state = 'present_verified';
    else if (receipt && retained.length === receipt.beforeCount && digest === receipt.beforeRowsSha256) state = 'not_committed_verified';
    else fail('Credential outcome cannot be reconciled with the receipt; manual review required');
    await client.query('COMMIT'); opened = false;
    return { mode: 'verify', state, credentialRowsVerified: retained.length,
      planSha256: plan.planSha256, databaseWrites: 0, standaloneLoginVerified: false };
  } finally { if (opened) await client.query('ROLLBACK').catch(() => {}); }
}
