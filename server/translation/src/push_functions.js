import { onRequest } from 'firebase-functions/v2/https';
import { onDocumentCreated } from 'firebase-functions/v2/firestore';
import { getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { FieldPath, FieldValue, getFirestore } from 'firebase-admin/firestore';
import { getMessaging } from 'firebase-admin/messaging';
import { createPushBackend, createPushHandler, PushError } from './push.js';

if (!getApps().length) initializeApp();
const enabled = () => process.env.CLRS_PUSH_ENABLED === 'true';
const backend = createPushBackend({
  db: getFirestore(), auth: getAuth(), messaging: getMessaging(),
  // Emulator checks may write only emulator inboxes and can never deliver FCM.
  sendEnabled: () => enabled() && process.env.FUNCTIONS_EMULATOR !== 'true',
  timestamp: () => FieldValue.serverTimestamp(), documentId: FieldPath.documentId(),
});
const shared = {
  region: 'europe-west1', memory: '256MiB', minInstances: 0, maxInstances: 2,
  serviceAccount: process.env.PUSH_SERVICE_ACCOUNT || undefined,
};

export const requestPush = onRequest({ ...shared, timeoutSeconds: 20,
  concurrency: 10, cors: false, invoker: 'public' },
createPushHandler({ auth: getAuth(), backend, enabled }));

function trigger(document, run) {
  return onDocumentCreated({ ...shared, document, timeoutSeconds: 120,
    concurrency: 1, retry: true }, async event => {
    if (!enabled() || !event.data) return;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 110000);
    try { await run(event.params, controller.signal, event.data.createTime, event.data.data()); }
    catch (error) {
      if (error instanceof PushError && error.status < 500) return;
      // Functions retries infrastructure failures without logging source data,
      // token query arguments or raw SDK exceptions.
      throw new Error('push_processing_unavailable');
    }
    finally { clearTimeout(timer); controller.abort(); }
  });
}

// Triggers survive a client closing immediately after its committed write.
// requestPush and these triggers share the same Firestore deduplication key.
export const pushPrivateMessage = trigger('chats/{entityId}/chats/{messageId}',
  (params, signal) => backend.message({ ...params, kind: 'chat', signal }));
export const pushMeetingMessage = trigger('meets/{entityId}/messages/{messageId}',
  (params, signal) => backend.message({ ...params, kind: 'group', signal }));
export const notifyPostComment = trigger('posts/{postId}/comments/{commentId}',
  (params, signal) => backend.comment({ ...params, signal }));
export const notifyPostLike = trigger('posts/{postId}/likes/{actorUid}',
  (params, signal) => backend.reaction({ ...params, signal }));
export const notifyCommentLike = trigger('posts/{postId}/comments/{commentId}/likes/{actorUid}',
  (params, signal) => backend.reaction({ ...params, signal }));
export const notifyFriendRequest = trigger('users/{recipientUid}/friend_requests/{actorUid}',
  (params, signal, sourceCreateTime) => backend.friendRequest({ ...params, sourceCreateTime, signal }));
export const notifyFriendAccepted = trigger('users/{recipientUid}/friends/{actorUid}',
  (params, signal, sourceCreateTime) => backend.friendAccepted({ ...params, sourceCreateTime, signal }));
export const notifyRegionalMeeting = trigger('meets/{entityId}',
  (params, signal, sourceCreateTime, sourceData) => backend.newMeeting({ ...params, sourceCreateTime, sourceData, signal }));
