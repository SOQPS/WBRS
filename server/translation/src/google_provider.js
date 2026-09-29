import { applicationDefault } from 'firebase-admin/app';
import { LANGUAGES, PublicError, assertActive } from './config.js';
import { toSerbianLatin } from './serbian_latin.js';

export const GOOGLE_CACHE_NAMESPACE = 'google-cloud-nmt-v1';
const MAX_RESPONSE_BYTES = 512 * 1024;
const MAX_RESULT_BYTES = 256 * 1024;
const PROJECT_ID = /^[a-z][a-z0-9-]{4,61}[a-z0-9]$/;
const LANGUAGE_CODE = /^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/;

async function boundedJson(response, signal) {
  const declared = response.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > MAX_RESPONSE_BYTES)) {
    await response.body?.cancel();
    throw new PublicError(503, 'translation_unavailable');
  }
  if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type') || '')) {
    await response.body?.cancel();
    throw new PublicError(503, 'translation_unavailable');
  }
  const reader = response.body?.getReader();
  if (!reader) throw new PublicError(503, 'translation_unavailable');
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      assertActive(signal);
      const { done, value } = await reader.read();
      assertActive(signal);
      if (done) break;
      size += value.byteLength;
      if (size > MAX_RESPONSE_BYTES) {
        await reader.cancel();
        throw new PublicError(503, 'translation_unavailable');
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size)));
}

// ADC stays on the server. A caller can select only one of the existing UI
// language codes; it cannot supply a credential, model, project, or endpoint.
export function createGoogleTranslator({
  credential = applicationDefault(),
  fetchImpl = fetch,
} = {}) {
  return async ({ text, targetLanguage, config, signal }) => {
    try {
      assertActive(signal);
      if (!config.enabled || config.provider !== 'google' || !PROJECT_ID.test(config.projectId) ||
          !LANGUAGES.includes(targetLanguage)) {
        throw new PublicError(503, 'translation_unavailable');
      }
      const access = await credential.getAccessToken();
      assertActive(signal);
      const token = access?.access_token;
      // RFC 6750 section 2.1 permits ~ + / and trailing =, never whitespace.
      if (typeof token !== 'string' || !token || token.length > 8192 ||
          !/^[A-Za-z0-9._~+\/-]+=*$/.test(token) || /\s/.test(token)) {
        throw new PublicError(503, 'translation_unavailable');
      }
      const parent = `projects/${config.projectId}/locations/global`;
      const response = await fetchImpl(`https://translate.googleapis.com/v3/${parent}:translateText`, {
        method: 'POST',
        redirect: 'error',
        signal,
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'x-goog-user-project': config.projectId,
        },
        body: JSON.stringify({
          contents: [text],
          mimeType: 'text/plain',
          targetLanguageCode: targetLanguage === 'nb' ? 'no' : targetLanguage,
          model: `${parent}/models/general/nmt`,
        }),
      });
      assertActive(signal);
      if (response.status !== 200) {
        await response.body?.cancel();
        throw new PublicError(503, 'translation_unavailable');
      }
      const result = await boundedJson(response, signal);
      assertActive(signal);
      const translation = result?.translations?.[0];
      const source = translation?.detectedLanguageCode;
      const translated = translation?.translatedText;
      if (!Array.isArray(result?.translations) || result.translations.length !== 1 ||
          typeof source !== 'string' || !LANGUAGE_CODE.test(source) ||
          typeof translated !== 'string' || !translated.trim() || !translated.isWellFormed() ||
          Buffer.byteLength(translated, 'utf8') > MAX_RESULT_BYTES) {
        throw new PublicError(503, 'translation_unavailable');
      }
      return {
        translatedText: targetLanguage === 'sr' ? toSerbianLatin(translated) : translated,
        detectedSourceLanguage: source === 'no' ? 'nb' : source,
        googlePowered: true,
      };
    } catch {
      // Google errors may contain text, account details or bearer credentials.
      // The endpoint handles user retries; never retry a paid request here.
      throw new PublicError(503, 'translation_unavailable');
    }
  };
}
