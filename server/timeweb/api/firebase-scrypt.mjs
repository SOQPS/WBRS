import { createCipheriv, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const deriveKey = promisify(scrypt);
const MEMORY_LIMIT = 64 * 1024 * 1024;

// Algorithm reference: Firebase's modified SCRYPT encrypts the project's
// signer key with AES-256-CTR using the first 32 bytes of a 64-byte scrypt key.
// https://github.com/firebase/scrypt/blob/master/lib/scryptenc/scryptenc.c
// N = 2^memoryCost, r = rounds, p = 1; salt is user salt + salt separator.
// This is deliberately not STANDARD_SCRYPT or a generic password hash.
export class CredentialCompatibilityError extends Error {
  constructor(code) {
    super('Credential verification is unavailable');
    this.name = 'CredentialCompatibilityError';
    this.code = code;
  }
}

export function decodeCredentialBase64(value, { allowEmpty = false, maxBytes = 4096 } = {}) {
  if (typeof value !== 'string' || (!value && !allowEmpty)
      || value.length > Math.ceil(maxBytes / 3) * 4
      || !/^[A-Za-z0-9+/_-]*={0,2}$/.test(value) || value.length % 4 === 1) {
    throw new CredentialCompatibilityError('ENCODING_UNSUPPORTED');
  }
  const decoded = Buffer.from(value, 'base64');
  const normalized = value.replaceAll('-', '+').replaceAll('_', '/').replace(/=+$/, '');
  if (decoded.length > maxBytes || decoded.toString('base64').replace(/=+$/, '') !== normalized
      || decoded.equals(Buffer.from('REDACTED'))) {
    decoded.fill(0);
    throw new CredentialCompatibilityError('ENCODING_UNSUPPORTED');
  }
  return decoded;
}

export function firebaseScryptParameters(config) {
  if (config?.algorithm !== 'SCRYPT' || !Number.isInteger(config.rounds)
      || config.rounds < 1 || config.rounds > 32 || !Number.isInteger(config.memoryCost)
      || config.memoryCost < 1 || config.memoryCost > 18) {
    throw new CredentialCompatibilityError('ALGORITHM_UNSUPPORTED');
  }
  const N = 2 ** config.memoryCost;
  // Include scrypt's auxiliary buffers; bound work before allocating memory.
  const requiredMemory = 128 * N * config.rounds + 128 * config.rounds + 1024;
  if (requiredMemory > MEMORY_LIMIT) {
    throw new CredentialCompatibilityError('KDF_LIMIT_EXCEEDED');
  }
  let signerKey; let saltSeparator;
  try {
    signerKey = decodeCredentialBase64(config.signerKey, { maxBytes: 256 });
    saltSeparator = decodeCredentialBase64(config.saltSeparator, { allowEmpty: true, maxBytes: 256 });
    if (signerKey.length < 16) throw new CredentialCompatibilityError('KEY_UNSUPPORTED');
    return { signerKey, saltSeparator, N, r: config.rounds, p: 1, maxmem: MEMORY_LIMIT };
  } catch (error) {
    signerKey?.fill(0); saltSeparator?.fill(0);
    throw error;
  }
}

export function assertFirebaseScryptCredential(record, config) {
  if (record?.kind !== 'auth-credential' || !record.passwordAccount
      || !record.materialAvailable || record.projectAlgorithm !== 'SCRYPT'
      || ![0, '0'].includes(record.material?.passwordVersion)) {
    throw new CredentialCompatibilityError('CREDENTIAL_VERSION_UNSUPPORTED');
  }
  const params = firebaseScryptParameters(config);
  let hash; let salt;
  try {
    hash = decodeCredentialBase64(record.material.passwordHash, { maxBytes: 256 });
    salt = decodeCredentialBase64(record.material.passwordSalt, { allowEmpty: true, maxBytes: 256 });
    if (hash.length !== params.signerKey.length) {
      throw new CredentialCompatibilityError('HASH_LENGTH_UNSUPPORTED');
    }
  } finally {
    hash?.fill(0); salt?.fill(0);
    params.signerKey.fill(0); params.saltSeparator.fill(0);
  }
}

// Server-only, asynchronous, bounded verifier. It never creates a session,
// changes a password, logs credentials, or calls Firebase.
export function createFirebaseScryptVerifier(config, { maxInFlight = 2 } = {}) {
  if (!Number.isInteger(maxInFlight) || maxInFlight < 1 || maxInFlight > 4) {
    throw new CredentialCompatibilityError('KDF_LIMIT_EXCEEDED');
  }
  const fixedConfig = structuredClone(config);
  const params = firebaseScryptParameters(fixedConfig);
  let active = 0;
  let disposed = false;
  return {
    async verify(record, password) {
      if (disposed) throw new CredentialCompatibilityError('VERIFIER_DISPOSED');
      assertFirebaseScryptCredential(record, fixedConfig);
      if (record.disabled === true) return false;
      if (typeof password !== 'string' || Buffer.byteLength(password, 'utf8') > 4096) {
        throw new CredentialCompatibilityError('PASSWORD_INPUT_INVALID');
      }
      if (active >= maxInFlight) throw new CredentialCompatibilityError('KDF_BUSY');
      const passwordBytes = Buffer.from(password, 'utf8');
      const expected = decodeCredentialBase64(record.material.passwordHash, { maxBytes: 256 });
      const userSalt = decodeCredentialBase64(record.material.passwordSalt, { allowEmpty: true, maxBytes: 256 });
      const salt = Buffer.concat([userSalt, params.saltSeparator]);
      let derived; let generated;
      active++;
      try {
        derived = await deriveKey(passwordBytes, salt, 64,
          { N: params.N, r: params.r, p: params.p, maxmem: params.maxmem });
        const cipher = createCipheriv('aes-256-ctr', derived.subarray(0, 32), Buffer.alloc(16));
        generated = Buffer.concat([cipher.update(params.signerKey), cipher.final()]);
        return timingSafeEqual(generated, expected);
      } catch (error) {
        if (error instanceof CredentialCompatibilityError) throw error;
        throw new CredentialCompatibilityError('KDF_FAILED');
      } finally {
        active--;
        passwordBytes.fill(0); expected.fill(0); userSalt.fill(0); salt.fill(0);
        derived?.fill(0); generated?.fill(0);
      }
    },
    dispose() {
      if (active) throw new CredentialCompatibilityError('KDF_BUSY');
      disposed = true;
      params.signerKey.fill(0); params.saltSeparator.fill(0);
    },
  };
}
