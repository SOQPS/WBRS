import { isDeepStrictEqual } from 'node:util';
import { readEncryptedArchive } from './encrypted-archive.mjs';

const PROJECT_RE = /^[a-z][a-z0-9-]{4,62}$/;
const ALGORITHMS = new Set(['SCRYPT', 'STANDARD_SCRYPT', 'BCRYPT', 'HMAC_SHA256',
  'HMAC_SHA1', 'HMAC_MD5', 'HMAC_SHA512', 'PBKDF_SHA1', 'PBKDF2_SHA256',
  'MD5', 'SHA1', 'SHA256', 'SHA512']);

function object(value) { return value && typeof value === 'object' && !Array.isArray(value); }
function validEncoded(value, allowEmpty = false) {
  return typeof value === 'string' && value.length <= 16384
    && (allowEmpty && !value || /^[A-Za-z0-9+/_-]+={0,2}$/.test(value))
    && value.length % 4 !== 1;
}
function redacted(value) {
  return typeof value === 'string' && Buffer.from(value, 'base64').toString('ascii') === 'REDACTED';
}

export function validateHashConfig(value) {
  if (!object(value) || !ALGORITHMS.has(value.algorithm)
      || (value.algorithm === 'SCRYPT' && (!validEncoded(value.signerKey)
        || redacted(value.signerKey) || !validEncoded(value.saltSeparator, true)
        || !Number.isInteger(value.rounds) || value.rounds < 1 || value.rounds > 32
        || !Number.isInteger(value.memoryCost) || value.memoryCost < 1 || value.memoryCost > 32))) {
    throw new Error('Usable password hash configuration is unavailable');
  }
  // Retain algorithm/config fields exactly; do not rewrite versions or keys.
  return structuredClone(value);
}

export function credentialRecord(raw, projectAlgorithm) {
  if (!object(raw) || typeof raw.localId !== 'string' || !raw.localId
      || raw.localId.length > 16384 || !Array.isArray(raw.providerUserInfo ?? [])) {
    throw new Error('Invalid Auth credential record');
  }
  const providers = (raw.providerUserInfo ?? []).map((value) => {
    if (!object(value) || typeof value.providerId !== 'string' || !value.providerId) {
      throw new Error('Invalid Auth credential provider');
    }
    return value.providerId;
  });
  for (const field of ['passwordHash', 'salt']) {
    if (raw[field] !== undefined && !validEncoded(raw[field], true)) {
      throw new Error('Invalid encoded Auth credential');
    }
  }
  if (raw.version !== undefined && !(typeof raw.version === 'number'
      && Number.isSafeInteger(raw.version) && raw.version >= 0)
      && !(typeof raw.version === 'string' && /^\d{1,20}$/.test(raw.version))) {
    throw new Error('Invalid password hash version');
  }
  const passwordAccount = providers.includes('password')
    || (typeof raw.passwordHash === 'string' && raw.passwordHash.length > 0);
  const materialAvailable = !!raw.passwordHash && !redacted(raw.passwordHash)
    && typeof raw.salt === 'string' && !redacted(raw.salt);
  return { kind: 'auth-credential', uid: raw.localId, providers,
    passwordAccount, materialAvailable, projectAlgorithm, schemeVerified: false,
    disabled: raw.disabled === true, emailVerified: raw.emailVerified === true,
    validSince: raw.validSince ?? null,
    material: { passwordHash: raw.passwordHash ?? null,
      passwordSalt: raw.salt ?? null, passwordVersion: raw.version ?? null } };
}

export function createCredentialRestAdapter({ credential, project, fetchImpl = fetch }) {
  if (!credential || typeof credential.getAccessToken !== 'function'
      || !PROJECT_RE.test(project) || typeof fetchImpl !== 'function') {
    throw new Error('Invalid Auth credential export configuration');
  }
  async function request(url) {
    const token = await credential.getAccessToken();
    if (!token?.access_token) throw new Error('Auth credential export token unavailable');
    const headers = { Authorization: `Bearer ${token.access_token}` };
    const quotaProject = credential.getQuotaProjectId?.();
    if (quotaProject) {
      if (!PROJECT_RE.test(quotaProject)) throw new Error('Invalid quota project');
      headers['x-goog-user-project'] = quotaProject;
    }
    const response = await fetchImpl(url, { method: 'GET', headers,
      signal: AbortSignal.timeout(30000) });
    if (!response.ok) throw new Error('Auth credential export read refused');
    let body;
    try { body = await response.json(); } catch { throw new Error('Invalid Auth credential response'); }
    if (!object(body)) throw new Error('Invalid Auth credential response');
    return body;
  }
  return {
    async hashConfig() {
      const response = await request(`https://identitytoolkit.googleapis.com/admin/v2/projects/${project}/config`);
      return validateHashConfig(response.signIn?.hashConfig);
    },
    async listUsers(pageToken) {
      const url = new URL(`https://identitytoolkit.googleapis.com/v1/projects/${project}/accounts:batchGet`);
      url.searchParams.set('maxResults', '1000');
      if (pageToken !== undefined) {
        if (typeof pageToken !== 'string' || !pageToken) throw new Error('Invalid Auth credential page');
        url.searchParams.set('nextPageToken', pageToken);
      }
      const response = await request(url);
      if (!Array.isArray(response.users ?? [])
          || (response.nextPageToken !== undefined && typeof response.nextPageToken !== 'string')) {
        throw new Error('Invalid Auth credential page');
      }
      return { users: response.users ?? [], pageToken: response.nextPageToken || undefined };
    },
  };
}

function counts(algorithm) {
  return { authUsers: 0, passwordAccounts: 0, materialAvailable: 0,
    unavailablePasswordAccounts: 0, nonPasswordAccounts: 0,
    hashVersions: {}, projectAlgorithm: algorithm, standaloneLoginVerified: false };
}
function countUser(summary, user) {
  summary.authUsers++;
  if (user.passwordAccount) {
    summary.passwordAccounts++;
    if (user.materialAvailable) summary.materialAvailable++;
    else summary.unavailablePasswordAccounts++;
    const version = user.material.passwordVersion === null ? 'unknown' : String(user.material.passwordVersion);
    summary.hashVersions[version] = (summary.hashVersions[version] ?? 0) + 1;
  } else summary.nonPasswordAccounts++;
}

export async function exportAuthCredentials({ api, writer, project,
  maxUsers = 10000, maxPages = 12 }) {
  if (!PROJECT_RE.test(project) || !Number.isSafeInteger(maxUsers) || maxUsers < 1
      || !Number.isSafeInteger(maxPages) || maxPages < 1) throw new Error('Invalid credential export limits');
  const hashConfig = validateHashConfig(await api.hashConfig());
  await writer.writeJson({ kind: 'auth-credential-source', format: 1,
    project, scope: 'auth-credentials-only', completeSource: true,
    snapshotConsistent: false, standaloneLoginVerified: false,
    startedAt: new Date().toISOString() });
  await writer.writeJson({ kind: 'auth-hash-config', hashConfig });
  const summary = counts(hashConfig.algorithm);
  const uids = new Set();
  const tokens = new Set();
  let token;
  let pages = 0;
  do {
    if (++pages > maxPages) throw new Error('Auth credential page limit reached');
    const result = await api.listUsers(token);
    if (!Array.isArray(result?.users)) throw new Error('Invalid Auth credential page');
    for (const raw of result.users) {
      if (summary.authUsers >= maxUsers) throw new Error('Auth credential user limit reached');
      const user = credentialRecord(raw, hashConfig.algorithm);
      if (uids.has(user.uid)) throw new Error('Duplicate Auth credential UID');
      uids.add(user.uid);
      countUser(summary, user);
      await writer.writeJson(user);
    }
    token = result.pageToken;
    if (token) {
      if (typeof token !== 'string' || tokens.has(token)) throw new Error('Repeated Auth credential page token');
      tokens.add(token);
    }
  } while (token);
  if (!isDeepStrictEqual(hashConfig, await api.hashConfig())) {
    throw new Error('Password configuration changed during export');
  }
  await writer.finish(summary);
  return summary;
}

export async function verifyAuthCredentialArchive({ archivePath, key, project }) {
  let state = 'source';
  let summary;
  let source;
  const uids = new Set();
  for await (const frame of readEncryptedArchive(archivePath, key)) {
    if (frame.type !== 'json') throw new Error('Unexpected credential archive byte frame');
    const record = frame.record;
    if (state === 'source') {
      if (record.kind !== 'auth-credential-source' || record.format !== 1
          || record.project !== project || record.scope !== 'auth-credentials-only'
          || record.completeSource !== true || record.standaloneLoginVerified !== false) {
        throw new Error('Unexpected credential archive source');
      }
      source = record;
      state = 'config';
    } else if (state === 'config') {
      if (record.kind !== 'auth-hash-config') throw new Error('Credential archive configuration missing');
      summary = counts(validateHashConfig(record.hashConfig).algorithm);
      state = 'users';
    } else if (state === 'users' && record.kind === 'auth-credential') {
      const rebuilt = credentialRecord({ localId: record.uid,
        providerUserInfo: record.providers?.map((providerId) => ({ providerId })),
        passwordHash: record.material?.passwordHash ?? undefined,
        salt: record.material?.passwordSalt ?? undefined,
        version: record.material?.passwordVersion ?? undefined,
        disabled: record.disabled, emailVerified: record.emailVerified,
        validSince: record.validSince }, summary.projectAlgorithm);
      if (!isDeepStrictEqual(record, rebuilt) || uids.has(record.uid)) {
        throw new Error('Invalid credential archive user');
      }
      uids.add(record.uid);
      countUser(summary, record);
    } else if (state === 'users' && record.kind === 'end') {
      if (!isDeepStrictEqual(record.summary, summary)) throw new Error('Credential archive totals mismatch');
      state = 'complete';
    } else throw new Error('Unexpected credential archive record');
  }
  if (state !== 'complete' || !source) throw new Error('Incomplete credential archive');
  return summary;
}
