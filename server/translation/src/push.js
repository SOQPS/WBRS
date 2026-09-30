import { createHash, randomUUID } from 'node:crypto';

const DAY = 86400000;
const DISCUSSION_WINDOW = 15 * 60000;
const id = value => typeof value === 'string' && value.length > 0 &&
  value.length <= 128 && !value.includes('/') && !value.includes('\0');
const hash = value => createHash('sha256').update(value).digest('hex');
const millis = value => typeof value?.toMillis === 'function' ? value.toMillis() :
  (value instanceof Date ? value.getTime() : NaN);
function timeParts(value) {
  if (Number.isSafeInteger(value?.seconds) && Number.isInteger(value?.nanoseconds) &&
      value.nanoseconds >= 0 && value.nanoseconds < 1000000000) {
    return [value.seconds, value.nanoseconds];
  }
  const time = millis(value);
  if (!Number.isSafeInteger(time)) return null;
  const seconds = Math.floor(time / 1000);
  return [seconds, (time - seconds * 1000) * 1000000];
}
// Firestore can delete/recreate a stable friend path within one millisecond.
// Keep nanosecond precision for both event identity and stale-event checks.
const generation = value => {
  const parts = timeParts(value);
  return parts ? `${parts[0]}:${String(parts[1]).padStart(9, '0')}` : null;
};
const sameTime = (a, b) => generation(a) !== null && generation(a) === generation(b);
function laterThan(a, b) {
  const left = timeParts(a), right = timeParts(b);
  return left && right && (left[0] > right[0] || left[0] === right[0] && left[1] > right[1]);
}
const active = profile => !!profile && !profile.deleted &&
  !['blocked', 'deleted'].includes(String(profile.status || '').toLowerCase()) &&
  profile.registrationStatus !== 'deleted' && profile.isRegistrationEnd !== false;
const array = value => Array.isArray(value) ? value.filter(id) : [];
const generic = {
  ru: 'У вас новое уведомление', en: 'You have a new notification',
  bg: 'Имате ново известие', cs: 'Máte nové oznámení', da: 'Du har en ny notifikation',
  de: 'Du hast eine neue Benachrichtigung', el: 'Έχετε μια νέα ειδοποίηση',
  es: 'Tienes una nueva notificación', fi: 'Sinulla on uusi ilmoitus',
  fr: 'Vous avez une nouvelle notification', hu: 'Új értesítése érkezett',
  is: 'Þú hefur fengið nýja tilkynningu', it: 'Hai una nuova notifica',
  mk: 'Имате ново известување', nb: 'Du har et nytt varsel', nl: 'Je hebt een nieuwe melding',
  pl: 'Masz nowe powiadomienie', pt: 'Você tem uma nova notificação',
  ro: 'Ai o notificare nouă', sk: 'Máte nové oznámenie', sl: 'Imate novo obvestilo',
  sr: 'Imate novo obaveštenje', sv: 'Du har en ny avisering',
};

export class PushError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
function check(signal) {
  if (signal?.aborted) throw new PushError(503, 'push_unavailable');
}
function fresh(snapshot, now) {
  const created = millis(snapshot.createTime);
  return Number.isFinite(created) && created <= now + 60000 && created >= now - DAY;
}

// Message data and recipients come from Firestore, never from the HTTP body.
// Private TOKENS documents must be owner-write only before enabling the service.
export function createPushBackend({ db, auth, messaging, now = () => Date.now(),
  sendEnabled = () => true, timestamp = () => new Date(), documentId = '__name__' }) {
  async function profile(uid) {
    if (!id(uid)) return null;
    const data = (await db.doc(`users/${uid}`).get()).data();
    if (!active(data)) return null;
    try {
      const user = await auth.getUser(uid);
      return user.uid === uid && !user.disabled ? data : null;
    } catch (error) {
      if (['auth/user-not-found', 'auth/user-disabled'].includes(error?.code)) return null;
      throw error;
    }
  }

  async function tokenFor(uid) {
    const entry = await db.doc(`TOKENS/${uid}`).get();
    const token = entry.data()?.token;
    if (typeof token !== 'string' || token.length < 20 || token.length > 4096) return null;
    // Offline logout can leave the same installation token on the previous
    // account. Its latest server commit owns it, irrespective of client clocks.
    const owners = await db.collection('TOKENS').where('token', '==', token).limit(10).get();
    if (owners.size === 10) return null;
    const sorted = [...owners.docs].sort((a, b) => millis(b.updateTime) - millis(a.updateTime));
    if (sorted[0]?.id !== uid || !Number.isFinite(millis(sorted[0].updateTime)) ||
        (sorted[1] && millis(sorted[0].updateTime) === millis(sorted[1].updateTime))) return null;
    return token;
  }

  async function reserveRequest(uid, signal) {
    if (!await profile(uid)) throw new PushError(403, 'account_not_allowed');
    const ref = db.doc(`_push_usage/${hash(uid)}`);
    const global = db.doc('_push_usage/global');
    await db.runTransaction(async tx => {
      const previous = await tx.get(ref), project = await tx.get(global);
      check(signal);
      const minute = Math.floor(now() / 60000);
      for (const [snapshot, limit] of [[previous, 60], [project, 3000]]) {
        const data = snapshot.data();
        if (data && (!Number.isSafeInteger(data.minute) || !Number.isSafeInteger(data.count) || data.count < 0)) {
          throw new PushError(503, 'push_unavailable');
        }
        if (data?.minute > minute || data?.minute === minute && data.count >= limit) {
          throw new PushError(429, 'push_limit');
        }
      }
      for (const [target, previousData] of [[ref, previous.data()], [global, project.data()]]) {
        tx.set(target, { minute, count: previousData?.minute === minute ? previousData.count + 1 : 1,
          ttlAt: new Date(now() + 2 * DAY) });
      }
    });
  }

  async function deliver(uid, eventKey, payload, recipientProfile, signal, validate, fanout, category) {
    check(signal);
    if (!sendEnabled()) return 'disabled';
    const token = await tokenFor(uid);
    check(signal);
    if (!token) return 'no_token';
    const delivery = db.doc(`_push_deliveries/${hash(`${eventKey}\0${uid}`)}`);
    const updateDelivery = async data => {
      if (!fanout) return delivery.update(data);
      return db.runTransaction(async tx => {
        const previous = await tx.get(delivery);
        if (previous.data()?.fanoutLeaseOwner === fanout.leaseOwner) tx.update(delivery, data);
      });
    };
    const reserved = await db.runTransaction(async tx => {
      const prior = await tx.get(delivery);
      if (fanout && !await fanout.validate(tx)) throw new PushError(503, 'push_unavailable');
      check(signal);
      if (prior.exists) return false;
      tx.set(delivery, { status: fanout ? 'reserved' : 'sending', recipientUid: uid,
        ...(fanout ? { fanoutLeaseOwner: fanout.leaseOwner } : {}),
        startedAt: timestamp(), ttlAt: new Date(now() + 30 * DAY) });
      return true;
    });
    if (!reserved) return 'duplicate';
    let sendStarted = false;
    try {
      check(signal);
      // Re-read token ownership and account eligibility immediately before FCM.
      const currentToken = await tokenFor(uid);
      const latestProfile = await profile(uid);
      if (currentToken !== token || !latestProfile ||
          category && latestProfile.notificationPreferences?.[category] === false ||
          validate && !await validate()) {
        await updateDelivery({ status: 'skipped' });
        return 'skipped';
      }
      if (fanout) {
        const allowed = await db.runTransaction(async tx => {
          const previous = await tx.get(delivery);
          const valid = await fanout.validate(tx);
          check(signal);
          if (previous.data()?.fanoutLeaseOwner !== fanout.leaseOwner || previous.data()?.status !== 'reserved') {
            throw new PushError(503, 'push_unavailable');
          }
          if (!valid) { tx.update(delivery, { status: 'skipped' }); return false; }
          // This claim is fenced by the current fanout lease. Only a reserved
          // delivery is recoverable; sending may have already reached FCM.
          tx.update(delivery, { status: 'sending' });
          return true;
        });
        if (!allowed) return 'skipped';
      }
      check(signal);
      const soundEnabled = latestProfile.notificationPreferences?.sound !== false;
      const language = String(latestProfile.language || latestProfile.locale || 'ru').split(/[-_]/)[0];
      sendStarted = true;
      await messaging.send({ token,
        notification: { title: 'CLRS', body: generic[language] || generic.en },
        data: { recipientUid: uid, soundEnabled: String(soundEnabled),
          payload: JSON.stringify({ ...payload, recipientUid: uid }) },
        android: { priority: 'high', ttl: DAY,
          notification: { channelId: soundEnabled ? 'wbrs' : 'wbrs_silent', tag: delivery.id } },
        apns: { headers: { 'apns-collapse-id': delivery.id },
          payload: { aps: soundEnabled ? { sound: 'default' } : {} } },
      });
      await updateDelivery({ status: 'sent', sentAt: timestamp() });
      return 'sent';
    } catch (error) {
      if (!sendStarted) {
        try {
          if (!fanout) await delivery.delete();
          else await db.runTransaction(async tx => {
            const previous = await tx.get(delivery), data = previous.data();
            if (data?.fanoutLeaseOwner !== fanout.leaseOwner) return;
            if (data.status === 'reserved') tx.delete(delivery);
            else if (data.status === 'sending') tx.update(delivery, { status: 'uncertain' });
          });
        } catch {}
        throw error;
      }
      // FCM and Firestore cannot commit atomically. Never automatically resend
      // an uncertain network result; that can duplicate a delivered push.
      const permanent = ['messaging/registration-token-not-registered',
        'messaging/invalid-registration-token'].includes(error?.code);
      try { await updateDelivery({ status: permanent ? 'invalid_token' : 'uncertain' }); } catch {}
      if (permanent) {
        try {
          await db.runTransaction(async tx => {
            const ref = db.doc(`TOKENS/${uid}`);
            if ((await tx.get(ref)).data()?.token === token) tx.update(ref, { token: '' });
          });
        } catch {}
      }
      return permanent ? 'invalid_token' : 'uncertain';
    }
  }

  async function message({ kind, entityId, messageId, senderUid, signal }) {
    if (!['chat', 'group'].includes(kind) || !id(entityId) || !id(messageId)) {
      throw new PushError(400, 'invalid_request');
    }
    const path = `${kind === 'chat' ? 'chats' : 'meets'}/${entityId}`;
    const [roomSnapshot, source] = await Promise.all([
      db.doc(path).get(), db.doc(`${path}/${kind === 'chat' ? 'chats' : 'messages'}/${messageId}`).get(),
    ]);
    check(signal);
    const room = roomSnapshot.data(), data = source.data();
    const actor = data?.sendByID || data?.sender;
    const members = kind === 'chat' ? [room?.user1, room?.user2].filter(id) : array(room?.users);
    if (!roomSnapshot.exists || !source.exists || !id(actor) || !members.includes(actor) ||
        (senderUid !== undefined && senderUid !== actor) || !await profile(actor)) {
      throw new PushError(403, 'message_not_allowed');
    }
    if (!fresh(source, now())) return { accepted: true, result: 'expired' };
    // Gifts have an image and notice in one transaction; notify only the notice.
    if (kind === 'chat' && messageId.startsWith('gift_image_')) {
      return { accepted: true, result: 'companion_image' };
    }
    const muted = array(kind === 'chat' ? room.usersWOutNotifications : room.usersWithoutNotification);
    const recipients = [...new Set(members)].filter(uid => uid !== actor && !muted.includes(uid));
    for (const uid of recipients) {
      check(signal);
      const recipient = await profile(uid);
      if (!recipient || recipient.notificationPreferences?.messages === false ||
          (kind === 'chat' && recipient.chatWithId === actor && recipient.online === true)) continue;
      await deliver(uid, `message:${kind}:${entityId}:${messageId}`,
        kind === 'chat' ? { isChat: true, chatId: entityId } : { isChat: false, groupId: entityId },
        recipient, signal, undefined, undefined, 'messages');
    }
    // Do not disclose recipient/token counts to the sender.
    return { accepted: true };
  }

  async function notice(uid, noticeId, data, signal, event = {}) {
    check(signal);
    if (event.key && !event.fanout && (await db.doc(`_push_deliveries/${hash(`${event.key}\0${uid}`)}`).get()).exists) return;
    const recipient = await profile(uid);
    if (!recipient) return;
    check(signal);
    const ref = db.doc(`users/${uid}/notifications/${noticeId}`);
    const written = await db.runTransaction(async tx => {
      const existing = await tx.get(ref);
      if (event.validate && !await event.validate(tx)) return false;
      check(signal);
      const previous = existing.data();
      if (event.sourceCreatedAt && laterThan(previous?.sourceCreatedAt, event.sourceCreatedAt)) return false;
      const newGeneration = event.sourceCreatedAt && !sameTime(previous?.sourceCreatedAt, event.sourceCreatedAt);
      // Retries preserve read; a new request at the same stable path is unread.
      // Older event generations must never overwrite the newer inbox entry.
      tx.set(ref, { ...data, read: !newGeneration && previous?.read === true,
        createdAt: newGeneration ? event.sourceCreatedAt : previous?.createdAt || timestamp(),
        ...(event.sourceCreatedAt ? { sourceCreatedAt: event.sourceCreatedAt } : {}) });
      return true;
    });
    if (!written) return;
    if (data.type === 'meeting' && recipient.notificationPreferences?.meetings === false) return;
    const validate = event.validate ? async () => {
      if (event.actorUid && !await profile(event.actorUid)) return false;
      return db.runTransaction(event.validate);
    } : undefined;
    await deliver(uid, event.key || `notice:${noticeId}`,
      event.payload || { kind: 'social', notificationId: noticeId }, recipient, signal,
      validate, event.fanout, data.type === 'meeting' ? 'meetings' : undefined);
  }

  async function friendRequest({ recipientUid, actorUid, sourceCreateTime, signal }) {
    if (!id(recipientUid) || !id(actorUid) || recipientUid === actorUid || !generation(sourceCreateTime)) return;
    const sourceRef = db.doc(`users/${recipientUid}/friend_requests/${actorUid}`);
    const mirrorRef = db.doc(`users/${actorUid}/friend_requests_sent/${recipientUid}`);
    const validate = async tx => {
      const [source, mirror, friendship, otherFriendship, actor, recipient] = await Promise.all([
        tx.get(sourceRef), tx.get(mirrorRef), tx.get(db.doc(`users/${recipientUid}/friends/${actorUid}`)),
        tx.get(db.doc(`users/${actorUid}/friends/${recipientUid}`)),
        tx.get(db.doc(`users/${actorUid}`)), tx.get(db.doc(`users/${recipientUid}`)),
      ]);
      check(signal);
      return source.exists && mirror.exists && !friendship.exists && !otherFriendship.exists &&
        active(actor.data()) && active(recipient.data()) &&
        sameTime(source.createTime, sourceCreateTime) && fresh(source, now()) &&
        sameTime(mirror.createTime, sourceCreateTime) &&
        source.data()?.fromUid === actorUid && source.data()?.status === 'pending' &&
        mirror.data()?.toUid === recipientUid && mirror.data()?.status === 'pending';
    };
    if (!await db.runTransaction(validate)) return;
    const actor = await profile(actorUid);
    if (!actor) return;
    await notice(recipientUid, `friend-request-${actorUid}`, {
      type: 'friend_request', title: 'Заявка в друзья', body: '', entityId: actorUid, actorUid,
      actorName: actor.fullName || '', actorPhoto: actor.profilePicThumb || actor.profilePic || '',
    }, signal, { sourceCreatedAt: sourceCreateTime, actorUid, validate,
      key: `friend-request:${recipientUid}:${actorUid}:${generation(sourceCreateTime)}` });
  }

  async function friendAccepted({ recipientUid, actorUid, sourceCreateTime, signal }) {
    if (!id(recipientUid) || !id(actorUid) || recipientUid === actorUid || !generation(sourceCreateTime)) return;
    const sourceRef = db.doc(`users/${recipientUid}/friends/${actorUid}`);
    const mirrorRef = db.doc(`users/${actorUid}/friends/${recipientUid}`);
    const validate = async tx => {
      const [source, mirror, actor, recipient] = await Promise.all([
        tx.get(sourceRef), tx.get(mirrorRef), tx.get(db.doc(`users/${actorUid}`)), tx.get(db.doc(`users/${recipientUid}`)),
      ]);
      check(signal);
      return source.exists && mirror.exists && active(actor.data()) && active(recipient.data()) &&
        sameTime(source.createTime, sourceCreateTime) && fresh(source, now()) &&
        sameTime(mirror.createTime, sourceCreateTime) &&
        source.data()?.uid === actorUid && mirror.data()?.uid === recipientUid &&
        source.data()?.acceptedByUid === actorUid && mirror.data()?.acceptedByUid === actorUid;
    };
    // The accepter's own mirror points at the requester and is deliberately
    // skipped. Legacy records without a protected acceptedByUid are not proof.
    if (!await db.runTransaction(validate)) return;
    const actor = await profile(actorUid);
    if (!actor) return;
    await notice(recipientUid, `friend-accepted-${actorUid}`, {
      type: 'friend_accepted', title: 'Заявка принята', body: '', entityId: actorUid, actorUid,
      actorName: actor.fullName || '', actorPhoto: actor.profilePicThumb || actor.profilePic || '',
    }, signal, { sourceCreatedAt: sourceCreateTime, actorUid, validate,
      key: `friend-accepted:${recipientUid}:${actorUid}:${generation(sourceCreateTime)}` });
  }

  async function newMeeting({ entityId, sourceCreateTime, sourceData, signal }) {
    if (!id(entityId) || !generation(sourceCreateTime) || sourceData?.type !== 'групповая' ||
        !id(sourceData.admin)) return;
    const sourceRef = db.doc(`meets/${entityId}`);
    const source = await sourceRef.get(), meeting = source.data();
    check(signal);
    if (!source.exists || !sameTime(source.createTime, sourceCreateTime) || !fresh(source, now()) ||
        meeting?.type !== 'групповая' || meeting.admin !== sourceData.admin ||
        meeting.country !== sourceData.country || meeting.region !== sourceData.region ||
        typeof meeting.country !== 'string' || !meeting.country.trim() || meeting.country.length > 128 ||
        typeof meeting.region !== 'string' || !meeting.region.trim() || meeting.region.length > 256 ||
        !array(meeting.users).includes(meeting.admin)) return;
    const actorUid = meeting.admin, country = meeting.country, region = meeting.region;
    const actor = await profile(actorUid);
    if (!actor) return;
    const eventKey = `new-meeting:${entityId}:${generation(sourceCreateTime)}`;
    const progressRef = db.doc(`_push_fanouts/${hash(eventKey)}`);
    const leaseOwner = randomUUID(), leaseUntil = new Date(now() + 120000);
    const cursorId = value => typeof value === 'string' && value.length <= 1500 &&
      !value.includes('/') && !value.includes('\0');
    const compareUid = (left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right));
    const validMeeting = current => {
      const data = current.data();
      return current.exists && sameTime(current.createTime, sourceCreateTime) && fresh(current, now()) &&
        data?.type === 'групповая' && data.admin === actorUid && data.country === country && data.region === region &&
        array(data.users).includes(actorUid);
    };
    const validProgress = data => data?.kind === 'new_meeting' && data.meetingId === entityId &&
      sameTime(data.sourceCreatedAt, sourceCreateTime) && cursorId(data.afterUid) && typeof data.completed === 'boolean' &&
      (data.leaseOwner === null || typeof data.leaseOwner === 'string' && data.leaseOwner.length <= 64) &&
      (data.leaseUntil === null || Number.isFinite(millis(data.leaseUntil)));
    const initial = await db.runTransaction(async tx => {
      const [progress, current, organizer] = await Promise.all([
        tx.get(progressRef), tx.get(sourceRef), tx.get(db.doc(`users/${actorUid}`)),
      ]);
      check(signal);
      if (!validMeeting(current) || !active(organizer.data())) return null;
      const previous = progress.data();
      if (progress.exists && !validProgress(previous)) throw new PushError(503, 'push_unavailable');
      if (previous?.completed) return previous;
      // Only one worker may turn a recipient's result into cursor progress.
      // Otherwise a duplicate of an in-flight delivery can skip an eventual
      // recoverable failure before FCM releases its reservation.
      if (previous?.leaseOwner && millis(previous.leaseUntil) > now()) throw new PushError(503, 'push_unavailable');
      const state = { kind: 'new_meeting', meetingId: entityId, sourceCreatedAt: sourceCreateTime,
        afterUid: previous?.afterUid || '', completed: false, leaseOwner, leaseUntil,
        updatedAt: timestamp(), ttlAt: new Date(now() + 2 * DAY) };
      tx.set(progressRef, state);
      return state;
    });
    if (!initial || initial.completed) return;
    let afterUid = initial.afterUid;
    const checkpoint = async (uid, complete = false) => db.runTransaction(async tx => {
      const [progress, current, organizer] = await Promise.all([
        tx.get(progressRef), tx.get(sourceRef), tx.get(db.doc(`users/${actorUid}`)),
      ]);
      check(signal);
      if (!validMeeting(current) || !active(organizer.data())) return null;
      const previous = progress.data();
      if (!validProgress(previous) || previous.leaseOwner !== leaseOwner || millis(previous.leaseUntil) <= now()) {
        throw new PushError(503, 'push_unavailable');
      }
      if (previous.completed) return previous;
      const nextUid = compareUid(uid, previous.afterUid) > 0 ? uid : previous.afterUid;
      const state = { ...previous, afterUid: nextUid,
        completed: complete && uid === nextUid, updatedAt: timestamp() };
      if (state.completed) { state.leaseOwner = null; state.leaseUntil = null; }
      tx.set(progressRef, state);
      return state;
    });
    try {
      for (;;) {
        check(signal);
        let query = db.collection('users').where('country', '==', country).where('region', '==', region)
          .select('country', 'region').orderBy(documentId).limit(250);
        // A value cursor still works if the last processed profile was deleted.
        if (afterUid) query = query.startAfter(afterUid);
        const page = await query.get();
        for (const target of page.docs) {
          const uid = target.id;
          if (compareUid(uid, afterUid) <= 0) continue;
          if (id(uid) && uid !== actorUid) {
            const validate = async tx => {
              const [current, recipient, organizer, progress] = await Promise.all([
                tx.get(sourceRef), tx.get(db.doc(`users/${uid}`)), tx.get(db.doc(`users/${actorUid}`)), tx.get(progressRef),
              ]);
              check(signal);
              const profileData = recipient.data(), state = progress.data();
              return validMeeting(current) && active(organizer.data()) && active(profileData) &&
                profileData.country === country && profileData.region === region && validProgress(state) &&
                !state.completed && state.leaseOwner === leaseOwner && millis(state.leaseUntil) > now();
            };
            const deliveryRef = db.doc(`_push_deliveries/${hash(`${eventKey}\0${uid}`)}`);
            const shouldProcess = await db.runTransaction(async tx => {
              const previous = await tx.get(deliveryRef), data = previous.data();
              if (!await validate(tx)) return false;
              if (!previous.exists) return true;
              if (data?.status === 'reserved') {
                if (data.fanoutLeaseOwner === leaseOwner) throw new PushError(503, 'push_unavailable');
                // A previous worker has lost its lease and cannot claim FCM.
                // Its late cleanup is fenced from this replacement reservation.
                tx.delete(deliveryRef);
                return true;
              }
              if (data?.status === 'sending') tx.update(deliveryRef, { status: 'uncertain' });
              else if (!['sent', 'skipped', 'uncertain', 'invalid_token'].includes(data?.status)) {
                throw new PushError(503, 'push_unavailable');
              }
              return false;
            });
            if (shouldProcess) await notice(uid, `new-meeting-${entityId}`, {
              type: 'meeting', kind: 'regional', title: 'Встреча', body: '', entityId, actorUid,
              actorName: actor.fullName || '', actorPhoto: actor.profilePicThumb || actor.profilePic || '',
            }, signal, { sourceCreatedAt: sourceCreateTime, actorUid, validate, key: eventKey,
              fanout: { leaseOwner, validate },
              payload: { kind: 'new_meeting', isChat: false, groupId: entityId } });
          }
          // A failed notice/delivery/checkpoint leaves this UID available on
          // retry. A completed or uncertain delivery keeps its existing dedup.
          const progress = await checkpoint(uid);
          if (!progress) return;
          afterUid = progress.afterUid;
        }
        if (page.size < 250) {
          const progress = await checkpoint(afterUid, true);
          if (!progress || progress.completed) return;
          afterUid = progress.afterUid;
        }
      }
    } finally {
      // Preserve the last committed UID even when releasing a failed attempt.
      // If the process dies, the bounded lease expires for the next retry.
      try {
        await db.runTransaction(async tx => {
          const progress = await tx.get(progressRef), state = progress.data();
          if (state?.leaseOwner === leaseOwner) {
            tx.set(progressRef, { ...state, leaseOwner: null, leaseUntil: null, updatedAt: timestamp() });
          }
        });
      } catch {}
    }
  }

  async function comment({ postId, commentId, signal }) {
    if (!id(postId) || !id(commentId)) throw new PushError(400, 'invalid_request');
    const [postSnapshot, source] = await Promise.all([
      db.doc(`posts/${postId}`).get(), db.doc(`posts/${postId}/comments/${commentId}`).get(),
    ]);
    check(signal);
    const post = postSnapshot.data(), data = source.data();
    if (post?.status !== 'published' || !data || !id(data.authorUid) || !fresh(source, now())) return;
    const actor = await profile(data.authorUid);
    if (!actor) return;
    const parentId = id(data.parentId) ? data.parentId : null;
    const parent = parentId ? (await db.doc(`posts/${postId}/comments/${parentId}`).get()).data() : null;
    if (parentId && !parent) return;
    const direct = parentId ? parent.authorUid : post.authorUid;
    const participants = new Set(id(post.authorUid) ? [post.authorUid] : []);
    // Read only participant identity fields in bounded pages. Existing comments
    // are the source of membership, including threads created before deployment.
    let cursor;
    for (;;) {
      check(signal);
      let query = db.collection(`posts/${postId}/comments`).select('authorUid')
        .orderBy(documentId).limit(250);
      if (cursor) query = query.startAfter(cursor);
      const page = await query.get();
      for (const doc of page.docs) {
        if (millis(doc.createTime) <= millis(source.createTime) && id(doc.data()?.authorUid)) {
          participants.add(doc.data().authorUid);
        }
      }
      if (page.size < 250) break;
      cursor = page.docs.at(-1);
    }
    if (id(direct)) participants.add(direct);
    participants.delete(data.authorUid);
    for (const uid of participants) {
      check(signal);
      const immediate = uid === direct;
      const noticeId = immediate ? `comment-${commentId}` :
        `discussion-${hash(postId).slice(0, 32)}-${Math.floor(millis(source.createTime) / DISCUSSION_WINDOW)}`;
      await notice(uid, noticeId, {
        type: immediate && parentId ? 'comment_reply' : 'post_comment',
        title: immediate && parentId ? 'Ответ на комментарий' : 'Новый комментарий',
        body: '', entityId: postId, actorUid: data.authorUid,
        actorName: actor.fullName || '', actorPhoto: actor.profilePicThumb || actor.profilePic || '',
        rootCommentId: parentId || commentId,
      }, signal);
    }
  }

  async function reaction({ postId, commentId, actorUid, signal }) {
    if (!id(postId) || !id(actorUid) || (commentId && !id(commentId))) return;
    const path = `posts/${postId}${commentId ? `/comments/${commentId}` : ''}`;
    const [post, source, like] = await Promise.all([db.doc(`posts/${postId}`).get(),
      db.doc(path).get(), db.doc(`${path}/likes/${actorUid}`).get()]);
    if (post.data()?.status !== 'published' || !source.exists || !like.exists ||
        like.data()?.uid !== actorUid || !fresh(like, now())) return;
    const target = source.data().authorUid;
    if (!id(target) || target === actorUid || !await profile(actorUid)) return;
    await notice(target, `reaction-${postId}-${commentId || 'post'}-${actorUid}`, {
      type: commentId ? 'comment_like' : 'post_like', title: 'Новая реакция', body: '',
      entityId: postId, actorUid,
      ...(commentId ? { rootCommentId: source.data().parentId || commentId } : {}),
    }, signal);
  }

  return { message, comment, reaction, friendRequest, friendAccepted, newMeeting, reserveRequest };
}

export function createPushHandler({ auth, backend, enabled = () => false, deadlineMs = 12000 }) {
  return async (req, res) => {
    res.set('Cache-Control', 'no-store, private');
    const controller = new AbortController();
    let timer;
    try {
      const operation = async () => {
        if (req.method !== 'POST') throw new PushError(405, 'method_not_allowed');
        if (!enabled()) throw new PushError(503, 'push_unavailable');
        if (!/^application\/json(?:\s*;|$)/i.test(req.headers?.['content-type'] || '') ||
            req.headers?.['content-encoding'] && req.headers['content-encoding'] !== 'identity' ||
            !Buffer.isBuffer(req.rawBody) || req.rawBody.length > 2048) {
          throw new PushError(400, 'invalid_request');
        }
        let body;
        try { body = JSON.parse(req.rawBody.toString('utf8')); } catch { throw new PushError(400, 'invalid_request'); }
        if (!body || Object.keys(body).sort().join(',') !== 'entityId,kind,messageId' ||
            !['chat', 'group'].includes(body.kind) || !id(body.entityId) || !id(body.messageId)) {
          throw new PushError(400, 'invalid_request');
        }
        const header = req.headers.authorization;
        if (typeof header !== 'string' || header.length > 8192 || !/^Bearer [A-Za-z0-9_.-]+$/.test(header)) {
          throw new PushError(401, 'unauthenticated');
        }
        let identity;
        try { identity = await auth.verifyIdToken(header.slice(7), true); } catch (error) {
          if (String(error?.code).startsWith('auth/')) throw new PushError(401, 'unauthenticated');
          throw error;
        }
        check(controller.signal);
        if (!id(identity?.uid) || identity.firebase?.sign_in_provider === 'anonymous') {
          throw new PushError(403, 'account_not_allowed');
        }
        await backend.reserveRequest(identity.uid, controller.signal);
        check(controller.signal);
        return backend.message({ ...body, senderUid: identity.uid, signal: controller.signal });
      };
      const timeout = new Promise((_, reject) => { timer = setTimeout(() => {
        controller.abort(); reject(new PushError(503, 'push_unavailable'));
      }, deadlineMs); });
      res.status(200).json(await Promise.race([operation(), timeout]));
    } catch (error) {
      const safe = error instanceof PushError ? error : new PushError(503, 'push_unavailable');
      if (safe.status === 405) res.set('Allow', 'POST');
      if (safe.status === 429) res.set('Retry-After', '60');
      res.status(safe.status).json({ error: { code: safe.code } });
    } finally { clearTimeout(timer); controller.abort(); }
  };
}
