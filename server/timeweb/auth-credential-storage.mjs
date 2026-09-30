import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { credentialRecord } from './auth-credentials-core.mjs';
import { assertFirebaseScryptCredential } from './api/firebase-scrypt.mjs';
import { assertMigrationGrants } from './mysql84-schema-core.mjs';

const DATABASE = 'clrs_staging';
function fail() { throw new Error('Credential storage validation failed'); }
function validUid(uid) {
  return typeof uid === 'string' && uid.length > 0 && [...uid].length <= 191 && !uid.includes('\0');
}
function configIdentity(config) {
  return createHash('sha256').update(JSON.stringify([config.algorithm, config.signerKey,
    config.saltSeparator, config.rounds, config.memoryCost])).digest('hex');
}
function validateStore({ configRef, wrappingKey }) {
  if (typeof configRef !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(configRef)
      || !Buffer.isBuffer(wrappingKey) || wrappingKey.length !== 32) fail();
}
function aad(uid, parameters, part) {
  // MySQL JSON canonicalizes object key order. Bind named fields in a fixed
  // order instead of depending on object serialization order after readback.
  return Buffer.from(JSON.stringify([DATABASE, 'auth_credentials', uid, part,
    parameters.material_format, parameters.config_ref, parameters.config_identity,
    parameters.password_version, parameters.providers, parameters.disabled,
    parameters.email_verified, parameters.valid_since]), 'utf8');
}
function seal(bytes, key, associatedData) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(associatedData);
  const ciphertext = Buffer.concat([cipher.update(bytes), cipher.final()]);
  return Buffer.concat([nonce, cipher.getAuthTag(), ciphertext]);
}
function open(bytes, key, associatedData) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 28 || bytes.length > 1024) fail();
  try {
    const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
    decipher.setAAD(associatedData);
    decipher.setAuthTag(bytes.subarray(12, 28));
    return Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]);
  } catch { fail(); }
}

// Uses the existing table without DDL. Its BLOBs hold authenticated ciphertext;
// signerKey stays in a separate server secret identified by configRef.
export function prepareEncryptedCredentialRow(record, { hashConfig, configRef, wrappingKey }) {
  validateStore({ configRef, wrappingKey });
  if (!validUid(record?.uid)) fail();
  if (!(record.validSince === null || (typeof record.validSince === 'string' && /^\d{1,20}$/.test(record.validSince))
      || (Number.isSafeInteger(record.validSince) && record.validSince >= 0))) fail();
  assertFirebaseScryptCredential(record, hashConfig);
  const rebuilt = credentialRecord({ localId: record.uid,
    providerUserInfo: record.providers?.map((providerId) => ({ providerId })),
    passwordHash: record.material.passwordHash, salt: record.material.passwordSalt,
    version: record.material.passwordVersion, disabled: record.disabled,
    emailVerified: record.emailVerified, validSince: record.validSince }, 'SCRYPT');
  if (!isDeepStrictEqual(record, rebuilt)) fail();
  const parameters = {
    material_format: 'aes256gcm-v1', config_ref: configRef,
    config_identity: configIdentity(hashConfig), password_version: record.material.passwordVersion,
    providers: [...record.providers], disabled: record.disabled,
    email_verified: record.emailVerified, valid_since: record.validSince,
  };
  // Preserve the exact original encoding as well as its bytes; URL-safe and
  // padded/unpadded exports must not be rewritten during migration.
  const hash = Buffer.from(record.material.passwordHash, 'utf8');
  const salt = Buffer.from(record.material.passwordSalt, 'utf8');
  try {
    return { uid: record.uid, scheme: 'firebase_scrypt', parameters,
      password_hash: seal(hash, wrappingKey, aad(record.uid, parameters, 'hash')),
      password_salt: seal(salt, wrappingKey, aad(record.uid, parameters, 'salt')) };
  } finally { hash.fill(0); salt.fill(0); }
}

export function decodeEncryptedCredentialRow(row, { hashConfig, configRef, wrappingKey }) {
  validateStore({ configRef, wrappingKey });
  let parameters;
  try {
    parameters = typeof row?.parameters === 'string'
      ? JSON.parse(row.parameters) : row?.parameters;
  } catch { fail(); }
  if (!validUid(row?.uid) || row.scheme !== 'firebase_scrypt'
      || parameters?.material_format !== 'aes256gcm-v1' || parameters.config_ref !== configRef
      || parameters.config_identity !== configIdentity(hashConfig)
      || Object.keys(parameters).sort().join(',') !== 'config_identity,config_ref,disabled,email_verified,material_format,password_version,providers,valid_since'
      || !Array.isArray(parameters.providers) || typeof parameters.disabled !== 'boolean'
      || typeof parameters.email_verified !== 'boolean') fail();
  let hash; let salt;
  try {
    hash = open(row.password_hash, wrappingKey, aad(row.uid, parameters, 'hash'));
    salt = open(row.password_salt, wrappingKey, aad(row.uid, parameters, 'salt'));
    const record = credentialRecord({ localId: row.uid,
      providerUserInfo: parameters.providers.map((providerId) => ({ providerId })),
      passwordHash: hash.toString('utf8'), salt: salt.toString('utf8'),
      version: parameters.password_version, disabled: parameters.disabled,
      emailVerified: parameters.email_verified, validSince: parameters.valid_since }, 'SCRYPT');
    assertFirebaseScryptCredential(record, hashConfig);
    return record;
  } finally { hash?.fill(0); salt?.fill(0); }
}

async function select(client, sql, values = []) {
  const [rows] = await client.execute(sql, values);
  if (!Array.isArray(rows)) fail();
  return rows;
}

// A pinned mysql2/promise connection from mysql84Config, never a Pool or a
// client-supplied connection string. No account creation or role mutation here.
export function createMySql84CredentialAdapter(client, expectedDatabase, secrets) {
  if (expectedDatabase !== DATABASE) fail();
  validateStore(secrets);
  let transaction = null;
  function requireOpen(write = false) {
    if (transaction === null || (write && transaction !== 'write')) fail();
  }
  async function stored(uid, forUpdate = false) {
    return select(client, `SELECT uid, scheme, password_hash, password_salt, parameters
      FROM clrs_staging.auth_credentials WHERE uid = ?${forUpdate ? ' FOR UPDATE' : ''}`, [uid]);
  }
  async function account(uid, forUpdate = false) {
    const rows = await select(client, `SELECT uid, disabled, email_verified, lifecycle
      FROM clrs_staging.accounts WHERE uid = ?${forUpdate ? ' FOR UPDATE' : ''}`, [uid]);
    if (rows.length !== 1 || rows[0].uid !== uid
        || ![0, 1].includes(rows[0].disabled) || ![0, 1].includes(rows[0].email_verified)
        || !['active', 'blocked', 'deleted'].includes(rows[0].lifecycle)) fail();
    return rows[0];
  }
  return {
    async begin({ readOnly = true } = {}) {
      if (transaction !== null || typeof readOnly !== 'boolean') fail();
      if (!readOnly) {
        const [grants] = await client.query('SHOW GRANTS');
        assertMigrationGrants(grants);
        let denied = false;
        try { await client.query('USE default_db'); }
        catch (error) {
          if (error?.code === 'ER_DBACCESS_DENIED_ERROR' && error?.errno === 1044) denied = true;
          else fail();
        }
        if (!denied) fail();
      }
      await client.query("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'");
      const [targets] = await client.query('SELECT DATABASE() AS target, VERSION() AS version');
      const [tls] = await client.query("SHOW SESSION STATUS LIKE 'Ssl_cipher'");
      const migrations = await select(client,
        'SELECT version FROM clrs_staging.schema_migrations ORDER BY version');
      if (targets.length !== 1 || targets[0].target !== DATABASE
          || !/^8\.4\./.test(targets[0].version ?? '') || tls.length !== 1 || !tls[0].Value
          || migrations.length !== 1 || Number(migrations[0].version) !== 1) fail();
      await client.query(`SET TRANSACTION ISOLATION LEVEL ${readOnly ? 'REPEATABLE READ' : 'SERIALIZABLE'}`);
      await client.query(`START TRANSACTION${readOnly ? ' READ ONLY' : ''}`);
      transaction = readOnly ? 'read' : 'write';
    },
    async stage(record) {
      requireOpen(true);
      const row = prepareEncryptedCredentialRow(record, secrets);
      const status = await account(record.uid, true);
      if (Boolean(status.disabled) !== record.disabled
          || Boolean(status.email_verified) !== record.emailVerified) fail();
      const existing = await stored(record.uid, true);
      if (existing.length > 1) fail();
      if (existing.length === 0) {
        await client.execute(`INSERT INTO clrs_staging.auth_credentials
          (uid, scheme, password_hash, password_salt, parameters, imported_at)
          VALUES (?, ?, ?, ?, ?, UTC_TIMESTAMP(6))`,
        [row.uid, row.scheme, row.password_hash, row.password_salt, JSON.stringify(row.parameters)]);
      }
      const retained = await stored(record.uid, true);
      if (retained.length !== 1
          || !isDeepStrictEqual(decodeEncryptedCredentialRow(retained[0], secrets), record)) fail();
    },
    async read(uid) {
      requireOpen();
      if (!validUid(uid)) fail();
      const status = await account(uid);
      const retained = await stored(uid);
      if (retained.length !== 1) fail();
      const credential = decodeEncryptedCredentialRow(retained[0], secrets);
      return { uid, lifecycle: status.lifecycle, disabled: Boolean(status.disabled),
        emailVerified: Boolean(status.email_verified), credential };
    },
    async authenticate(uid, password, verifier) {
      // Authorization uses the current migrated account state as well as
      // the preserved credential state; an old hash cannot revive an account.
      const retained = await this.read(uid);
      if (retained.lifecycle !== 'active' || retained.disabled) return null;
      if (!verifier || typeof verifier.verify !== 'function') fail();
      return await verifier.verify(retained.credential, password)
        ? { uid: retained.uid, emailVerified: retained.emailVerified } : null;
    },
    async commit() {
      requireOpen();
      await client.query('COMMIT');
      transaction = null;
    },
    async rollback() {
      if (transaction !== null) {
        try { await client.query('ROLLBACK'); } finally { transaction = null; }
      }
    },
  };
}
