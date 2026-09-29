import { region } from 'firebase-functions/v1';
import { getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { FieldPath, FieldValue, getFirestore } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { createAccountCleanup, createAuthDeleteCleanupHandler } from './account_cleanup.js';

if (!getApps().length) initializeApp();
const enabled = () => process.env.CLRS_ACCOUNT_CLEANUP_ENABLED === 'true';
const backend = createAccountCleanup({
  db: getFirestore(), auth: getAuth(), bucket: () => getStorage().bucket(), enabled,
  timestamp: () => FieldValue.serverTimestamp(), deleteField: () => FieldValue.delete(),
  documentId: FieldPath.documentId(),
});

// Auth lifecycle onDelete is the v1 API of the installed Functions SDK. A
// Firestore "deleted" write alone cannot invoke trusted deletion of resources.
export const cleanupDeletedProfile = region('europe-west1').runWith({
  memory: '256MB', timeoutSeconds: 180, minInstances: 0, maxInstances: 1,
  failurePolicy: true,
  ...(process.env.ACCOUNT_CLEANUP_SERVICE_ACCOUNT ?
    { serviceAccount: process.env.ACCOUNT_CLEANUP_SERVICE_ACCOUNT } : {}),
}).auth.user().onDelete(createAuthDeleteCleanupHandler({ backend, enabled }));
