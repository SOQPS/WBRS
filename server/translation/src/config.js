export const LANGUAGES = Object.freeze('en de es fr it pt el ru sr pl sl sk cs bg ro mk hu sv nb fi da nl is'.split(' '));
export const MAX_CODEPOINTS = 5000;
export const MAX_BODY_BYTES = 32768;
export const MAX_SOURCE_BYTES = 10000;
export const DEADLINE_MS = 18000;
// Availability changes over time; operator must select a region with both
// Translate and Comprehend. This only rejects malformed server configuration.
const REGION_PATTERN = /^[a-z]{2}(?:-[a-z0-9]+){1,3}-[1-9][0-9]?$/;

export class PublicError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

function positiveInt(env, key, fallback, max) {
  const value = env[key];
  if (value === undefined || value === '') return fallback;
  if (!/^[1-9][0-9]*$/.test(value)) throw new PublicError(503, 'translation_unavailable');
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number > max) throw new PublicError(503, 'translation_unavailable');
  return number;
}

export function readConfig(env = process.env, provider = 'amazon') {
  const projectId = env.GCLOUD_PROJECT || env.GOOGLE_CLOUD_PROJECT || '';
  const awsRegion = env.AWS_REGION || env.AWS_DEFAULT_REGION || '';
  const encodedKey = env.TRANSLATION_CACHE_HMAC_KEY || '';
  const decodedKey = /^[A-Za-z0-9+/]{43}=$/.test(encodedKey) ? Buffer.from(encodedKey, 'base64') : null;
  return Object.freeze({
    // Emulators must never make a paid translation request accidentally.
    enabled: (provider === 'google' ? env.GOOGLE_TRANSLATION_ENABLED : env.TRANSLATION_ENABLED) === 'true' && env.FUNCTIONS_EMULATOR !== 'true',
    provider,
    providerValid: provider === 'amazon' || provider === 'google',
    projectId,
    projectValid: /^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(projectId),
    awsRegion,
    awsRegionValid: REGION_PATTERN.test(awsRegion),
    cacheKey: decodedKey?.length === 32 && decodedKey.toString('base64') === encodedKey ? decodedKey : null,
    uidDailyChars: positiveInt(env, 'TRANSLATION_UID_DAILY_CHARS', 20000, 100000),
    globalDailyChars: positiveInt(env, 'TRANSLATION_GLOBAL_DAILY_CHARS', 200000, 1000000),
    uidMinuteRequests: positiveInt(env, 'TRANSLATION_UID_MINUTE_REQUESTS', 10, 60),
    globalMinuteRequests: positiveInt(env, 'TRANSLATION_GLOBAL_MINUTE_REQUESTS', 100, 600),
  });
}

export function assertActive(signal) {
  if (signal.aborted) throw new PublicError(503, 'translation_unavailable');
}
