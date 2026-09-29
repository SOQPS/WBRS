import { DEADLINE_MS, LANGUAGES, MAX_BODY_BYTES, MAX_CODEPOINTS, MAX_SOURCE_BYTES, PublicError, assertActive } from './config.js';

export function validateBody(req) {
  const contentType = String(req.headers?.['content-type'] || '').toLowerCase();
  if (!/^application\/json(?:\s*;|$)/.test(contentType)) throw new PublicError(400, 'invalid_request');
  const encoding = req.headers?.['content-encoding'];
  if (encoding && encoding !== 'identity') throw new PublicError(400, 'invalid_request');
  const declaredLength = req.headers?.['content-length'];
  if (declaredLength !== undefined && (!/^\d+$/.test(String(declaredLength)) || Number(declaredLength) > MAX_BODY_BYTES)) {
    throw new PublicError(413, 'request_too_large');
  }
  // Firebase's onRequest supplies rawBody; validate it as well as parsed JSON.
  if (!Buffer.isBuffer(req.rawBody)) throw new PublicError(400, 'invalid_request');
  if (req.rawBody.byteLength > MAX_BODY_BYTES) throw new PublicError(413, 'request_too_large');
  let body;
  try { body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(req.rawBody)); } catch { throw new PublicError(400, 'invalid_request'); }
  if (!body || Array.isArray(body) || typeof body !== 'object' || Object.keys(body).sort().join(',') !== 'targetLanguage,text') {
    throw new PublicError(400, 'invalid_request');
  }
  if (typeof body.text !== 'string' || !body.text.trim() || !body.text.isWellFormed() || body.text.includes('\u0000')) {
    throw new PublicError(400, 'invalid_request');
  }
  const chars = [...body.text].length;
  if (chars > MAX_CODEPOINTS || Buffer.byteLength(body.text, 'utf8') > MAX_SOURCE_BYTES) throw new PublicError(413, 'request_too_large');
  if (typeof body.targetLanguage !== 'string' || !LANGUAGES.includes(body.targetLanguage)) {
    throw new PublicError(400, 'unsupported_language');
  }
  return { text: body.text, targetLanguage: body.targetLanguage, chars };
}

function bearer(req) {
  const value = req.headers?.authorization;
  if (typeof value !== 'string' || value.length > 8192 || !/^Bearer [A-Za-z0-9_.-]+$/.test(value)) {
    throw new PublicError(401, 'unauthenticated');
  }
  return value.slice(7);
}

function invalidIdentity(error) {
  return ['auth/argument-error', 'auth/invalid-id-token', 'auth/id-token-expired', 'auth/id-token-revoked', 'auth/user-disabled', 'auth/user-not-found'].includes(error?.code);
}

export function createHandler({ getConfig, auth, reserve, translate, cache, deadlineMs = DEADLINE_MS }) {
  return async (req, res) => {
    res.set('Cache-Control', 'no-store, private');
    res.set('Pragma', 'no-cache');
    res.set('X-Content-Type-Options', 'nosniff');
    const controller = new AbortController();
    let timer;
    const operation = async () => {
      if (req.method !== 'POST') throw new PublicError(405, 'method_not_allowed');
      const config = getConfig();
      if (!config.enabled || !config.projectValid || !config.providerValid ||
          (config.provider === 'amazon' && !config.awsRegionValid) ||
          !config.cacheKey || !cache) throw new PublicError(503, 'translation_unavailable');
      const input = validateBody(req);
      const token = bearer(req);
      let decoded, user;
      try {
        // checkRevoked=true also rejects disabled users; getUser requires a real account.
        decoded = await auth.verifyIdToken(token, true);
        assertActive(controller.signal);
        if (typeof decoded?.uid !== 'string' || !decoded.uid || decoded.uid.length > 128 || decoded.uid.includes('/') || decoded.firebase?.sign_in_provider === 'anonymous') {
          throw new PublicError(403, 'account_not_allowed');
        }
        user = await auth.getUser(decoded.uid);
      } catch (error) {
        if (error instanceof PublicError) throw error;
        if (invalidIdentity(error)) throw new PublicError(401, 'unauthenticated');
        throw new PublicError(503, 'translation_unavailable');
      }
      assertActive(controller.signal);
      // Email/password-only UserRecord may legitimately have providerData=[].
      // The verified, non-anonymous ID token and live Auth user establish identity.
      if (user.uid !== decoded.uid || user.disabled) {
        throw new PublicError(403, 'account_not_allowed');
      }
      await reserve({ uid: decoded.uid, chars: input.chars, config, signal: controller.signal });
      assertActive(controller.signal);
      const translated = await cache.getOrTranslate({
        uid: decoded.uid, text: input.text, targetLanguage: input.targetLanguage,
        config, signal: controller.signal, translate,
      });
      assertActive(controller.signal);
      return { translatedText: translated.translatedText, detectedSourceLanguage: translated.detectedSourceLanguage, targetLanguage: input.targetLanguage,
        ...(config.provider === 'google' ? { googlePowered: true } : {}) };
    };
    try {
      const expiry = new Promise((_, reject) => {
        timer = setTimeout(() => { controller.abort(); reject(new PublicError(503, 'translation_unavailable')); }, Math.min(DEADLINE_MS, deadlineMs));
      });
      const result = await Promise.race([operation(), expiry]);
      res.status(200).json(result);
    } catch (error) {
      // Never log request text, token, provider response, or exception objects.
      const safe = error instanceof PublicError ? error : new PublicError(503, 'translation_unavailable');
      if (safe.status === 405) res.set('Allow', 'POST');
      if (safe.status === 429) res.set('Retry-After', '60');
      res.status(safe.status).json({ error: { code: safe.code } });
    } finally {
      clearTimeout(timer);
      controller.abort();
    }
  };
}
