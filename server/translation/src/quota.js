import { createHash } from 'node:crypto';
import { PublicError, assertActive } from './config.js';

export const USAGE_COLLECTION = '_translation_usage';
function number(data, key) {
  const value = data?.[key] ?? 0;
  // Corrupt counters fail closed; do not reset them to zero.
  if (!Number.isSafeInteger(value) || value < 0) throw new PublicError(503, 'translation_unavailable');
  return value;
}

export function createReservation({ db, now = () => Date.now() }) {
  return async ({ uid, chars, config, signal }) => {
    assertActive(signal);
    if (!Number.isSafeInteger(chars) || chars < 1 || chars > 5000) throw new PublicError(400, 'invalid_request');
    const hash = createHash('sha256').update(uid).digest('hex');
    const userRef = db.collection('users').doc(uid);
    const usage = db.collection(USAGE_COLLECTION);
    await db.runTransaction(async tx => {
      assertActive(signal);
      // Capture the day inside each attempt, not before a delayed/retried transaction.
      const date = new Date(now()).toISOString().slice(0, 10);
      const uidRef = usage.doc(`uid_${hash}_${date}`);
      const globalRef = usage.doc(`global_${date}`);
      // All reads precede writes. Firestore retries concurrent conflicts.
      const [profile, userUsage, projectUsage] = await tx.getAll(userRef, uidRef, globalRef);
      assertActive(signal);
      const profileData = profile.data();
      const status = String(profileData?.status || '').trim().toLowerCase();
      const registrationStatus = String(profileData?.registrationStatus || '').trim().toLowerCase();
      if (!profile.exists || profileData?.deleted === true ||
          status === 'blocked' || status === 'deleted' ||
          registrationStatus === 'deleted') throw new PublicError(403, 'account_not_allowed');
      const userData = userUsage.data();
      const globalData = projectUsage.data();
      const currentTime = now();
      // Never commit a reservation to yesterday after crossing UTC midnight.
      if (new Date(currentTime).toISOString().slice(0, 10) !== date) throw new PublicError(503, 'translation_unavailable');
      // Clock skew or a delayed request must never move either bucket backwards.
      const minute = Math.max(Math.floor(currentTime / 60000), number(userData, 'minute'), number(globalData, 'minute'));
      const userTotal = number(userData, 'chars') + chars;
      const globalTotal = number(globalData, 'chars') + chars;
      const userRequests = (userData?.minute === minute ? number(userData, 'requests') : 0) + 1;
      const globalRequests = (globalData?.minute === minute ? number(globalData, 'requests') : 0) + 1;
      if (userTotal > config.uidDailyChars || globalTotal > config.globalDailyChars || userRequests > config.uidMinuteRequests || globalRequests > config.globalMinuteRequests) {
        throw new PublicError(429, 'translation_limit');
      }
      assertActive(signal);
      // Only aggregate usage; no plaintext, content hashes, tokens or translations.
      tx.set(uidRef, { chars: userTotal, minute, requests: userRequests });
      tx.set(globalRef, { chars: globalTotal, minute, requests: globalRequests });
    }, { maxAttempts: 3 });
    // A transaction already committing cannot be cancelled. Its reservation stays charged.
    assertActive(signal);
  };
}
