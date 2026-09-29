import { createHmac, randomUUID } from 'node:crypto';
import { PublicError, assertActive } from './config.js';

export const CACHE_COLLECTION = '_translation_cache';
const LEASE_MS = 25000;
const CACHE_MS = 7 * 24 * 60 * 60 * 1000;
const WAIT_MS = 120;

function key(secret, namespace, uid, source, target, text) {
  return createHmac('sha256', secret)
    .update(JSON.stringify([namespace, uid, source, target, text]))
    .digest('hex');
}

function validSource(value) {
  return typeof value === 'string' && /^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/.test(value);
}

function wait(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(new PublicError(503, 'translation_unavailable'));
    const onAbort = () => {
      clearTimeout(timer);
      reject(new PublicError(503, 'translation_unavailable'));
    };
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    signal.addEventListener('abort', onAbort, { once: true });
    if (signal.aborted) onAbort();
  });
}

// The auto alias permits a hit before language detection. A separate canonical
// record is keyed by the provider's actual detected source language. Both keys
// include UID, input text and target; only the HMAC digest is a Firestore ID.
export function createTranslationCache({ db, now = () => Date.now(), waitMs = WAIT_MS,
  namespace = 'amazon-translate-v1' }) {
  if (!['amazon-translate-v1', 'google-cloud-nmt-v1'].includes(namespace)) {
    throw new PublicError(503, 'translation_unavailable');
  }
  const googlePowered = namespace === 'google-cloud-nmt-v1';
  const collection = db.collection(CACHE_COLLECTION);
  return {
    async getOrTranslate({ uid, text, targetLanguage, config, signal, translate }) {
      const aliasId = `a_${key(config.cacheKey, namespace, uid, 'auto', targetLanguage, text)}`;
      const aliasRef = collection.doc(aliasId);
      const claimId = randomUUID();
      let claimed = false;
      try {
        while (true) {
          assertActive(signal);
          const decision = await db.runTransaction(async tx => {
            assertActive(signal);
            const snapshot = await tx.get(aliasRef);
            const alias = snapshot.data();
            const clock = now();
            if (alias?.status === 'ready' &&
                Number.isSafeInteger(alias.expiresAt) && alias.expiresAt > clock) {
              const source = alias.detectedSourceLanguage;
              const expectedId = `r_${key(config.cacheKey, namespace, uid, source, targetLanguage, text)}`;
              if (!validSource(source) || alias.canonicalId !== expectedId) {
                throw new PublicError(503, 'translation_unavailable');
              }
              const record = (await tx.get(collection.doc(expectedId))).data();
              if (!Number.isSafeInteger(record?.expiresAt) || record.expiresAt <= clock ||
                  record?.targetLanguage !== targetLanguage ||
                  record?.detectedSourceLanguage !== source ||
                  (googlePowered && record?.googlePowered !== true) ||
                  typeof record?.translatedText !== 'string' ||
                  !record.translatedText.trim() || !record.translatedText.isWellFormed() ||
                  Buffer.byteLength(record.translatedText, 'utf8') > 256 * 1024) {
                throw new PublicError(503, 'translation_unavailable');
              }
              return { kind: 'hit', value: {
                translatedText: record.translatedText,
                detectedSourceLanguage: source,
                ...(googlePowered ? { googlePowered: true } : {}),
              } };
            }
            if (alias?.status === 'pending' && alias.leaseUntil > clock) {
              return { kind: 'wait' };
            }
            assertActive(signal);
            tx.set(aliasRef, {
              status: 'pending', claimId, leaseUntil: clock + LEASE_MS,
              ttlAt: new Date(clock + CACHE_MS),
            });
            return { kind: 'claimed' };
          }, { maxAttempts: 3 });
          assertActive(signal);
          if (decision.kind === 'hit') return decision.value;
          if (decision.kind === 'claimed') { claimed = true; break; }
          await wait(waitMs, signal);
        }

        const value = await translate({ text, targetLanguage, config, signal });
        assertActive(signal);
        if (!validSource(value?.detectedSourceLanguage) ||
            typeof value?.translatedText !== 'string' ||
            !value.translatedText.trim() || !value.translatedText.isWellFormed() ||
            Buffer.byteLength(value.translatedText, 'utf8') > 256 * 1024 ||
            (googlePowered && value.googlePowered !== true)) {
          throw new PublicError(503, 'translation_unavailable');
        }
        const canonicalId = `r_${key(config.cacheKey, namespace, uid, value.detectedSourceLanguage, targetLanguage, text)}`;
        await db.runTransaction(async tx => {
          assertActive(signal);
          const snapshot = await tx.get(aliasRef);
          if (snapshot.data()?.claimId !== claimId) throw new PublicError(503, 'translation_unavailable');
          const clock = now();
          const expiry = clock + CACHE_MS;
          tx.set(collection.doc(canonicalId), {
            translatedText: value.translatedText,
            detectedSourceLanguage: value.detectedSourceLanguage,
            targetLanguage, expiresAt: expiry, ttlAt: new Date(expiry),
            ...(googlePowered ? { googlePowered: true } : {}),
          });
          tx.set(aliasRef, {
            status: 'ready', canonicalId,
            detectedSourceLanguage: value.detectedSourceLanguage,
            expiresAt: expiry, ttlAt: new Date(expiry),
          });
        }, { maxAttempts: 3 });
        claimed = false;
        assertActive(signal);
        return value;
      } catch (error) {
        if (claimed) {
          try {
            await db.runTransaction(async tx => {
              const snapshot = await tx.get(aliasRef);
              if (snapshot.data()?.claimId === claimId) tx.delete(aliasRef);
            }, { maxAttempts: 3 });
          } catch { /* Lease expiry still permits a later retry. */ }
        }
        if (error instanceof PublicError) throw error;
        throw new PublicError(503, 'translation_unavailable');
      }
    },
  };
}
