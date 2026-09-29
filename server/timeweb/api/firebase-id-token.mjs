import { createPublicKey, verify as verifySignature } from 'node:crypto';

const PROJECT_ID = 'chatapp-4e347';
const ISSUER = `https://securetoken.google.com/${PROJECT_ID}`;
const CERTIFICATES_URL =
  'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';
const MAX_TOKEN_BYTES = 16 * 1024;
const MAX_KEYS_RESPONSE_BYTES = 128 * 1024;
const MAX_KEY_CACHE_SECONDS = 24 * 60 * 60;

export class FirebaseTokenVerificationError extends Error {
  constructor(code) {
    super(code === 'keys_unavailable' ? 'Firebase signing keys unavailable' : 'Invalid Firebase ID token');
    this.name = 'FirebaseTokenVerificationError';
    this.code = code;
  }
}

function invalidToken() {
  return new FirebaseTokenVerificationError('invalid_token');
}

function decodePart(part, maxBytes) {
  if (!part || !/^[A-Za-z0-9_-]+$/.test(part) || part.length % 4 === 1) {
    throw invalidToken();
  }
  const bytes = Buffer.from(part, 'base64url');
  if (bytes.length > maxBytes || bytes.toString('base64url') !== part) {
    throw invalidToken();
  }
  return bytes;
}

function decodeObject(part) {
  try {
    const value = JSON.parse(decodePart(part, 8 * 1024).toString('utf8'));
    if (value && typeof value === 'object' && !Array.isArray(value)) return value;
  } catch (error) {
    if (error instanceof FirebaseTokenVerificationError) throw error;
  }
  throw invalidToken();
}

function cacheSeconds(header) {
  const match = /(?:^|,)\s*max-age\s*=\s*(\d+)\s*(?:,|$)/i.exec(header ?? '');
  if (!match) return 0;
  return Math.min(Number(match[1]), MAX_KEY_CACHE_SECONDS);
}

/**
 * Verify Firebase client ID tokens without a service-account credential.
 * This is a temporary identity bridge: it does not check token revocation or
 * replace server-side authorization against CLRS's own user/role records.
 */
export function createFirebaseIdTokenVerifier({
  fetchImpl = globalThis.fetch,
  now = Date.now,
  timeoutMs = 3000,
} = {}) {
  if (typeof fetchImpl !== 'function' || typeof now !== 'function' ||
      !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30000) {
    throw new TypeError('Invalid Firebase token verifier configuration');
  }

  let keys = new Map();
  let keysExpireAt = 0;
  let inflight;

  async function refreshKeys() {
    const controller = new AbortController();
    let timer;
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(new FirebaseTokenVerificationError('keys_unavailable'));
      }, timeoutMs);
    });
    try {
      const loaded = await Promise.race([deadline, (async () => {
        const response = await fetchImpl(CERTIFICATES_URL, {
          method: 'GET',
          redirect: 'error',
          cache: 'no-store',
          headers: { accept: 'application/json' },
          signal: controller.signal,
        });
        if (!response.ok || Number(response.headers.get('content-length') || 0) >
            MAX_KEYS_RESPONSE_BYTES) {
          throw new Error('Invalid keys response');
        }
        const body = await response.text();
        if (Buffer.byteLength(body) > MAX_KEYS_RESPONSE_BYTES) {
          throw new Error('Oversized keys response');
        }
        const certificates = JSON.parse(body);
        if (!certificates || typeof certificates !== 'object' ||
            Array.isArray(certificates) || Object.keys(certificates).length === 0 ||
            Object.keys(certificates).length > 32) {
          throw new Error('Invalid keys response');
        }
        const nextKeys = new Map();
        for (const [kid, certificate] of Object.entries(certificates)) {
          if (!kid || kid.length > 200 || typeof certificate !== 'string' ||
              certificate.length > 10000) {
            throw new Error('Invalid certificate');
          }
          const publicKey = createPublicKey(certificate);
          if (publicKey.asymmetricKeyType !== 'rsa') {
            throw new Error('Invalid signing key type');
          }
          nextKeys.set(kid, publicKey);
        }
        return { keys: nextKeys, maxAge: cacheSeconds(response.headers.get('cache-control')) };
      })()]);
      keys = loaded.keys;
      keysExpireAt = now() + loaded.maxAge * 1000;
    } catch {
      throw new FirebaseTokenVerificationError('keys_unavailable');
    } finally {
      clearTimeout(timer);
    }
  }

  async function getKey(kid) {
    if (now() >= keysExpireAt || keys.size === 0) {
      inflight ??= refreshKeys().finally(() => { inflight = undefined; });
      await inflight;
    }
    const key = keys.get(kid);
    if (!key) throw invalidToken();
    return key;
  }

  return async function verifyFirebaseIdToken(token) {
    if (typeof token !== 'string' || Buffer.byteLength(token) > MAX_TOKEN_BYTES) {
      throw invalidToken();
    }
    const parts = token.split('.');
    if (parts.length !== 3) throw invalidToken();
    const [encodedHeader, encodedPayload, encodedSignature] = parts;
    const header = decodeObject(encodedHeader);
    if (header.alg !== 'RS256' || typeof header.kid !== 'string' ||
        !header.kid || header.kid.length > 200 ||
        (header.typ !== undefined && header.typ !== 'JWT') ||
        header.crit !== undefined) {
      throw invalidToken();
    }
    const signature = decodePart(encodedSignature, 8 * 1024);
    const key = await getKey(header.kid);
    if (!verifySignature('RSA-SHA256',
      Buffer.from(`${encodedHeader}.${encodedPayload}`, 'ascii'), key, signature)) {
      throw invalidToken();
    }
    const claims = decodeObject(encodedPayload);
    const nowSeconds = Math.floor(now() / 1000);
    if (claims.aud !== PROJECT_ID || claims.iss !== ISSUER ||
        typeof claims.sub !== 'string' || claims.sub.length < 1 ||
        Buffer.byteLength(claims.sub, 'utf8') > 128 ||
        !Number.isSafeInteger(claims.exp) || claims.exp <= nowSeconds ||
        !Number.isSafeInteger(claims.iat) || claims.iat <= 0 ||
        claims.iat > nowSeconds || claims.iat >= claims.exp ||
        !Number.isSafeInteger(claims.auth_time) || claims.auth_time <= 0 ||
        claims.auth_time > claims.iat) {
      throw invalidToken();
    }
    return Object.freeze({
      uid: claims.sub,
      issuedAt: claims.iat,
      authenticatedAt: claims.auth_time,
      expiresAt: claims.exp,
    });
  };
}
