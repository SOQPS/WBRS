import { region } from 'firebase-functions/v1';
import { getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { createPrivateEmailLifecycle, createPrivateEmailAuthHandler } from './private_email.js';

if (!getApps().length) initializeApp();
const enabled = () => process.env.CLRS_PRIVATE_EMAIL_PROVISION_ENABLED === 'true';
const backend = createPrivateEmailLifecycle({ db: getFirestore(), auth: getAuth(), enabled });
const runtime = region('europe-west1').runWith({
  memory: '256MB', timeoutSeconds: 30, minInstances: 0, maxInstances: 1,
  failurePolicy: true,
  ...(process.env.PRIVATE_EMAIL_SERVICE_ACCOUNT ?
    { serviceAccount: process.env.PRIVATE_EMAIL_SERVICE_ACCOUNT } : {}),
});
const handler = operation => createPrivateEmailAuthHandler({ backend, operation, enabled,
  report: safe => console.warn('private_email_review', safe),
});

// Auth v1 lifecycle events, not callable/client endpoints. Both are deployed
// together, with the same opt-in flag, before the private directory is enabled.
export const provisionPrivateEmail = runtime.auth.user().onCreate(handler('provision'));
export const fenceDeletedPrivateEmail = runtime.auth.user().onDelete(handler('remove'));
