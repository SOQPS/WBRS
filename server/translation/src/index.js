import { onRequest } from 'firebase-functions/v2/https';
import { initializeApp, getApps } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { readConfig } from './config.js';
import { createHandler } from './handler.js';
import { createReservation } from './quota.js';
import { createAmazonTranslator } from './provider.js';
import { createGoogleTranslator, GOOGLE_CACHE_NAMESPACE } from './google_provider.js';
import { createTranslationCache } from './cache.js';
export { requestPush, pushPrivateMessage, pushMeetingMessage,
  notifyPostComment, notifyPostLike, notifyCommentLike,
  notifyFriendRequest, notifyFriendAccepted, notifyRegionalMeeting } from './push_functions.js';
export { cleanupDeletedProfile } from './account_cleanup_functions.js';
export { provisionPrivateEmail, fenceDeletedPrivateEmail } from './private_email_functions.js';

if (!getApps().length) initializeApp();
const auth = getAuth();
const db = getFirestore();

export const translateContent = onRequest({
  region: 'europe-west1',
  serviceAccount: process.env.TRANSLATION_SERVICE_ACCOUNT || undefined,
  timeoutSeconds: 20,
  memory: '256MiB',
  minInstances: 0,
  maxInstances: 2,
  concurrency: 10,
  cors: false,
  // Store these in Secret Manager for this function only. AWS_REGION is
  // non-secret runtime configuration; no AWS secret is embedded in the APK.
  secrets: ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'TRANSLATION_CACHE_HMAC_KEY'],
  // Public transport is required for Firebase ID tokens; handler enforces account authorization.
  invoker: 'public',
}, createHandler({
  getConfig: () => readConfig(),
  auth,
  reserve: createReservation({ db }),
  translate: createAmazonTranslator(),
  cache: createTranslationCache({ db }),
}));

// Separate opt-in fallback: never binds AWS credentials to a Google function.
// The existing Amazon export and its configuration remain compatible.
export const translateContentGoogle = onRequest({
  region: 'europe-west1',
  serviceAccount: process.env.GOOGLE_TRANSLATION_SERVICE_ACCOUNT || undefined,
  timeoutSeconds: 20,
  memory: '256MiB',
  minInstances: 0,
  maxInstances: 2,
  concurrency: 10,
  cors: false,
  secrets: ['TRANSLATION_CACHE_HMAC_KEY'],
  invoker: 'public',
}, createHandler({
  getConfig: () => readConfig(process.env, 'google'),
  auth,
  reserve: createReservation({ db }),
  translate: createGoogleTranslator(),
  cache: createTranslationCache({ db, namespace: GOOGLE_CACHE_NAMESPACE }),
}));
