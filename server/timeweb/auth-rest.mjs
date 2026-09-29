// Firebase Admin user management requires a service account. This read-only
// REST endpoint accepts an IAM-authorized Google user ADC token as well.
const ENDPOINT = 'https://identitytoolkit.googleapis.com/v1/projects';

function utcDate(value) {
  if (value === undefined || value === null || value === '') return null;
  const milliseconds = Number(value);
  const date = new Date(milliseconds);
  return Number.isSafeInteger(milliseconds) && !Number.isNaN(date.getTime())
    ? date.toUTCString() : null;
}

function mapUser(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)
      || typeof raw.localId !== 'string' || !raw.localId) {
    throw new Error('Invalid Auth REST user');
  }
  const providerInfo = raw.providerUserInfo ?? [];
  if (!Array.isArray(providerInfo)) throw new Error('Invalid Auth REST providers');
  const providerData = providerInfo.map((provider) => {
    if (!provider || typeof provider.providerId !== 'string'
        || typeof provider.rawId !== 'string') {
      throw new Error('Invalid Auth REST provider');
    }
    return {
      uid: provider.rawId, providerId: provider.providerId,
      displayName: provider.displayName, email: provider.email,
      photoURL: provider.photoUrl, phoneNumber: provider.phoneNumber,
    };
  });
  let customClaims;
  if (raw.customAttributes !== undefined && raw.customAttributes !== '') {
    try { customClaims = JSON.parse(raw.customAttributes); }
    catch { throw new Error('Invalid Auth REST claims'); }
    if (!customClaims || typeof customClaims !== 'object'
        || Array.isArray(customClaims)) throw new Error('Invalid Auth REST claims');
  }
  const user = {
    uid: raw.localId, email: raw.email,
    emailVerified: raw.emailVerified === true,
    displayName: raw.displayName, photoURL: raw.photoUrl,
    phoneNumber: raw.phoneNumber, disabled: raw.disabled === true,
    providerData, customClaims, tenantId: raw.tenantId,
    metadata: {
      creationTime: utcDate(raw.createdAt),
      lastSignInTime: utcDate(raw.lastLoginAt),
      lastRefreshTime: raw.lastRefreshAt
        ? utcDate(Date.parse(raw.lastRefreshAt)) : null,
    },
    tokensValidAfterTime: raw.validSince
      ? utcDate(Number(raw.validSince) * 1000) : undefined,
  };
  // The Admin SDK's UserRecord omits some non-secret REST metadata. Keep it
  // in the encrypted archive for a later migration, never in the manifest.
  for (const field of ['language', 'timeZone', 'dateOfBirth', 'screenName',
    'customAuth', 'emailLinkSignin', 'initialEmail', 'mfaInfo']) {
    if (raw[field] !== undefined) user[field] = raw[field];
  }
  // Do not copy the REST response: it can contain passwordHash, salt and
  // version even when those fields are redacted for a viewer principal.
  return user;
}

export function createAuthRestAdapter({ credential, projectId, fetchImpl = fetch }) {
  if (!credential || typeof credential.getAccessToken !== 'function'
      || !/^[a-z][a-z0-9-]{4,62}$/.test(projectId)
      || typeof fetchImpl !== 'function') {
    throw new Error('Invalid Auth REST configuration');
  }
  return {
    async listUsers(maxResults, pageToken) {
      if (!Number.isSafeInteger(maxResults) || maxResults < 1 || maxResults > 1000
          || (pageToken !== undefined && (typeof pageToken !== 'string' || !pageToken))) {
        throw new Error('Invalid Auth REST page request');
      }
      const token = await credential.getAccessToken();
      if (typeof token?.access_token !== 'string' || !token.access_token) {
        throw new Error('Auth REST credential unavailable');
      }
      const url = new URL(`${ENDPOINT}/${projectId}/accounts:batchGet`);
      url.searchParams.set('maxResults', String(maxResults));
      if (pageToken) url.searchParams.set('nextPageToken', pageToken);
      const headers = { Authorization: `Bearer ${token.access_token}` };
      const quotaProject = credential.getQuotaProjectId?.();
      if (quotaProject) {
        if (!/^[a-z][a-z0-9-]{4,62}$/.test(quotaProject)) {
          throw new Error('Invalid Auth REST quota project');
        }
        headers['x-goog-user-project'] = quotaProject;
      }
      const response = await fetchImpl(url, {
        method: 'GET', headers, signal: AbortSignal.timeout(30000),
      });
      if (!response.ok) {
        // Google error bodies can include request context. Never log them.
        throw new Error(`Auth REST read failed (HTTP ${response.status})`);
      }
      let body;
      try { body = await response.json(); }
      catch { throw new Error('Invalid Auth REST response'); }
      if (!body || typeof body !== 'object' || Array.isArray(body)
          || (body.users !== undefined && !Array.isArray(body.users))
          || (body.nextPageToken !== undefined
            && typeof body.nextPageToken !== 'string')) {
        throw new Error('Invalid Auth REST response');
      }
      return {
        users: (body.users ?? []).map(mapUser),
        pageToken: body.nextPageToken || undefined,
      };
    },
  };
}
