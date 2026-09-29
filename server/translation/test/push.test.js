import assert from 'node:assert/strict';
import test from 'node:test';
import { createPushBackend, createPushHandler } from '../src/push.js';

const CLOCK = Date.UTC(2026, 8, 28, 12);
const snapshotTime = value => typeof value?.seconds === 'number' ?
  Object.defineProperty({ ...value }, 'toMillis', {
    value: () => value.seconds * 1000 + value.nanoseconds / 1000000,
  }) : new Date(value ?? NaN);
class Database {
  constructor() { this.docs = new Map(); this.queue = Promise.resolve(); this.tick = CLOCK; this.queryReads = []; }
  put(path, data, created = CLOCK, updated = ++this.tick) {
    const previous = this.docs.get(path);
    this.docs.set(path, { data: structuredClone(data), created: previous?.created ?? created, updated });
  }
  snap(path) {
    const entry = this.docs.get(path);
    return { id: path.split('/').at(-1), ref: this.doc(path), exists: !!entry,
      data: () => entry ? structuredClone(entry.data) : undefined,
      createTime: snapshotTime(entry?.created), updateTime: snapshotTime(entry?.updated) };
  }
  doc(path) { return { path, id: path.split('/').at(-1),
    get: async () => this.snap(path),
    update: async data => this.put(path, { ...this.docs.get(path)?.data, ...data }),
    delete: async () => this.docs.delete(path),
  }; }
  collection(path) { return new Query(this, path); }
  async runTransaction(fn) {
    const previous = this.queue;
    let release;
    this.queue = new Promise(resolve => { release = resolve; });
    await previous;
    const writes = [];
    try {
      const result = await fn({
        get: async ref => this.snap(ref.path),
        set: (ref, data) => writes.push(() => this.put(ref.path, data)),
        update: (ref, data) => writes.push(() => this.put(ref.path, { ...this.docs.get(ref.path)?.data, ...data })),
        delete: ref => writes.push(() => this.docs.delete(ref.path)),
      });
      for (const write of writes) write();
      return result;
    } finally { release(); }
  }
}
class Query {
  constructor(db, path, fields = [], count = Infinity, after = '') {
    Object.assign(this, { db, path, fields, count, after });
  }
  doc(id) { return this.db.doc(`${this.path}/${id}`); }
  where(key, op, value) { assert.equal(op, '=='); return new Query(this.db, this.path, [...this.fields, [key, value]], this.count, this.after); }
  limit(count) { return new Query(this.db, this.path, this.fields, count, this.after); }
  select() { return this; }
  orderBy() { return this; }
  startAfter(cursor) { return new Query(this.db, this.path, this.fields, this.count, typeof cursor === 'string' ? cursor : cursor.id); }
  async get() {
    this.db.queryReads.push({ path: this.path, after: this.after, count: this.count });
    const depth = this.path.split('/').length + 1;
    const docs = [...this.db.docs.keys()]
      .filter(path => path.startsWith(this.path + '/') && path.split('/').length === depth)
      .map(path => this.db.snap(path)).sort((a, b) => a.id.localeCompare(b.id))
      .filter(doc => doc.id > this.after && this.fields.every(([key, value]) => doc.data()[key] === value))
      .slice(0, this.count);
    return { docs, size: docs.length };
  }
}
function setup() {
  const db = new Database(), sent = [], disabled = new Set();
  const auth = {
    verifyIdToken: async (token, revoked) => {
      assert.equal(token, 'valid.jwt.token'); assert.equal(revoked, true);
      return { uid: 'a', firebase: { sign_in_provider: 'password' } };
    },
    getUser: async uid => ({ uid, disabled: disabled.has(uid) }),
  };
  const messaging = { send: async data => { sent.push(data); return 'fcm-id'; } };
  const backend = createPushBackend({ db, auth, messaging, now: () => CLOCK, timestamp: () => new Date(CLOCK) });
  const user = uid => {
    db.put(`users/${uid}`, { status: 'active', fullName: uid, language: 'en' });
    db.put(`TOKENS/${uid}`, { token: `installation-token-private-${uid}` });
  };
  for (const uid of ['a', 'b', 'c', 'd']) user(uid);
  db.put('chats/room', { user1: 'a', user2: 'b' });
  db.put('chats/room/chats/msg', { sendByID: 'a', message: 'PRIVATE MESSAGE TEXT' });
  const input = { kind: 'chat', entityId: 'room', messageId: 'msg', senderUid: 'a' };
  return { db, auth, messaging, backend, sent, disabled, user, input };
}
const signal = () => new AbortController().signal;
function request(body = { kind: 'chat', entityId: 'room', messageId: 'msg' }) {
  return { method: 'POST', headers: { authorization: 'Bearer valid.jwt.token', 'content-type': 'application/json' }, rawBody: Buffer.from(JSON.stringify(body)) };
}
function response() { return { statusCode: 0, body: null, headers: {},
  set(key, value) { this.headers[key] = value; return this; },
  status(code) { this.statusCode = code; return this; }, json(body) { this.body = body; return this; },
}; }

test('HTTP accepts only authenticated message references, never a client token or arbitrary recipient', async () => {
  const h = setup(), handler = createPushHandler({ ...h, enabled: () => true });
  for (const body of [{ kind: 'chat', entityId: 'room', messageId: 'msg', token: 'forged' },
    { kind: 'chat', entityId: '../room', messageId: 'msg' }, { kind: 'chat', entityId: 'room' }]) {
    const res = response(); await handler(request(body), res); assert.equal(res.statusCode, 400);
  }
  const req = request(); delete req.headers.authorization;
  const missing = response(); await handler(req, missing); assert.equal(missing.statusCode, 401);
  const ok = response(); await handler(request(), ok); assert.equal(ok.statusCode, 200);
  assert.deepEqual(ok.body, { accepted: true }); assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].token, 'installation-token-private-b');
  assert.equal(JSON.stringify(ok.body).includes('token'), false);
});

test('endpoint is disabled by default and revoked/anonymous accounts are rejected', async () => {
  const h = setup(); const disabled = response();
  await createPushHandler(h)(request(), disabled); assert.equal(disabled.statusCode, 503);
  h.auth.verifyIdToken = async () => { throw { code: 'auth/id-token-revoked', message: 'SECRET' }; };
  const revoked = response(); await createPushHandler({ ...h, enabled: () => true })(request(), revoked);
  assert.equal(revoked.statusCode, 401); assert.equal(JSON.stringify(revoked.body).includes('SECRET'), false);
  h.auth.verifyIdToken = async () => ({ uid: 'a', firebase: { sign_in_provider: 'anonymous' } });
  const anon = response(); await createPushHandler({ ...h, enabled: () => true })(request(), anon);
  assert.equal(anon.statusCode, 403); assert.equal(h.sent.length, 0);
});

test('real sender, room membership and active account are required', async () => {
  const h = setup();
  await assert.rejects(h.backend.message({ ...h.input, senderUid: 'c' }), e => e.status === 403);
  h.db.put('chats/room', { user1: 'b', user2: 'c' });
  await assert.rejects(h.backend.message(h.input), e => e.status === 403);
  h.db.put('chats/room', { user1: 'a', user2: 'b' });
  h.disabled.add('a');
  await assert.rejects(h.backend.message(h.input), e => e.status === 403);
  assert.equal(h.sent.length, 0);
});

test('parallel trigger and HTTP retries send each recipient at most once', async () => {
  const h = setup();
  await Promise.all(Array.from({ length: 8 }, () => h.backend.message(h.input)));
  assert.equal(h.sent.length, 1);
  const rows = [...h.db.docs].filter(([key]) => key.startsWith('_push_deliveries/'));
  assert.equal(rows.length, 1); assert.equal(rows[0][1].data.status, 'sent');
});

test('muted and blocked recipients are excluded from group fanout', async () => {
  const h = setup();
  h.db.put('meets/event', { users: ['a', 'b', 'c', 'd', 'b'], usersWithoutNotification: ['c'] });
  h.db.put('meets/event/messages/msg', { sender: 'a' });
  h.disabled.add('d');
  await h.backend.message({ kind: 'group', entityId: 'event', messageId: 'msg', senderUid: 'a' });
  assert.equal(h.sent.length, 1); assert.equal(h.sent[0].token, 'installation-token-private-b');
  assert.deepEqual(JSON.parse(h.sent[0].data.payload), { isChat: false, groupId: 'event', recipientUid: 'b' });
});

test('same installation token belongs only to latest account server write and contains no private preview', async () => {
  const h = setup();
  h.db.put('TOKENS/c', { token: 'installation-token-private-b' });
  await h.backend.message(h.input); assert.equal(h.sent.length, 0);
  h.db.put('TOKENS/b', { token: 'installation-token-private-b' });
  await h.backend.message(h.input); assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].notification.body, 'You have a new notification');
  assert.equal(JSON.stringify(h.sent[0]).includes('PRIVATE MESSAGE TEXT'), false);
});

test('expired messages and gift companion image cannot generate duplicate notifications', async () => {
  const h = setup();
  h.db.put('chats/room/chats/old', { sendByID: 'a' }, CLOCK - 2 * 86400000);
  h.db.put('chats/room/chats/gift_image_id', { sendByID: 'a', image: 'gift.png' });
  await h.backend.message({ ...h.input, messageId: 'old' });
  await h.backend.message({ ...h.input, messageId: 'gift_image_id' });
  assert.equal(h.sent.length, 0);
});

test('invalid token is removed only for the original account; uncertain FCM result is never replayed', async () => {
  for (const code of ['messaging/registration-token-not-registered', 'messaging/internal-error']) {
    const h = setup(); let calls = 0;
    h.messaging.send = async () => { calls++; throw { code }; };
    await h.backend.message(h.input); await h.backend.message(h.input);
    assert.equal(calls, 1);
    const status = [...h.db.docs].find(([key]) => key.startsWith('_push_deliveries/'))[1].data.status;
    assert.equal(status, code.endsWith('not-registered') ? 'invalid_token' : 'uncertain');
    assert.equal(h.db.snap('TOKENS/b').data().token === '', code.endsWith('not-registered'));
  }
});

test('HTTP deadline prevents a late auth completion from starting push work', async () => {
  const h = setup(); let release;
  h.auth.verifyIdToken = () => new Promise(resolve => { release = resolve; });
  const res = response();
  await createPushHandler({ ...h, enabled: () => true, deadlineMs: 5 })(request(), res);
  assert.equal(res.statusCode, 503);
  release({ uid: 'a' }); await new Promise(resolve => setTimeout(resolve, 1));
  assert.equal(h.sent.length, 0);
});

test('per-account request budget is atomic and blocks excessive retries', async () => {
  const h = setup();
  const results = await Promise.allSettled(Array.from({ length: 65 }, () => h.backend.reserveRequest('a', signal())));
  assert.equal(results.filter(x => x.status === 'fulfilled').length, 60);
  assert.ok(results.filter(x => x.status === 'rejected').every(x => x.reason.status === 429));
});

test('new comment alerts only post author and existing participants, with direct reply destination', async () => {
  const h = setup(); h.user('blocked'); h.disabled.add('blocked');
  h.db.put('posts/post', { status: 'published', authorUid: 'b' });
  h.db.put('posts/post/comments/root', { authorUid: 'c' }, CLOCK - 2000);
  h.db.put('posts/post/comments/blocked', { authorUid: 'blocked' }, CLOCK - 1000);
  h.db.put('posts/post/comments/new', { authorUid: 'a', parentId: 'root' }, CLOCK);
  h.db.put('posts/post/comments/later', { authorUid: 'd' }, CLOCK + 1000);
  await h.backend.comment({ postId: 'post', commentId: 'new' });
  assert.deepEqual(h.sent.map(x => x.data.recipientUid).sort(), ['b', 'c']);
  assert.equal(h.db.snap('users/c/notifications/comment-new').data().type, 'comment_reply');
  assert.equal(h.db.snap('users/c/notifications/comment-new').data().rootCommentId, 'root');
  for (const push of h.sent) {
    assert.equal(JSON.parse(push.data.payload).kind, 'social');
    assert.ok(JSON.parse(push.data.payload).notificationId);
  }
});

test('discussion fanout coalesces unrelated comments for 15 minutes and never overwrites read state', async () => {
  const h = setup();
  h.db.put('posts/post', { status: 'published', authorUid: 'b' });
  h.db.put('posts/post/comments/old', { authorUid: 'c' }, CLOCK - 1000);
  h.db.put('posts/post/comments/one', { authorUid: 'a' });
  h.db.put('posts/post/comments/two', { authorUid: 'a' });
  await h.backend.comment({ postId: 'post', commentId: 'one' });
  const cNotice = [...h.db.docs.keys()].find(key => key.startsWith('users/c/notifications/'));
  await h.db.doc(cNotice).update({ read: true });
  await h.backend.comment({ postId: 'post', commentId: 'two' });
  assert.equal(h.sent.filter(x => x.data.recipientUid === 'c').length, 1);
  assert.equal(h.sent.filter(x => x.data.recipientUid === 'b').length, 2);
  assert.equal(h.db.snap(cNotice).data().read, true);
  await h.backend.comment({ postId: 'post', commentId: 'two' });
  assert.equal(h.sent.length, 3);
});

test('participant scan continues after first bounded page', async () => {
  const h = setup();
  h.db.put('posts/post', { status: 'published', authorUid: 'a' });
  for (let n = 0; n < 251; n++) h.db.put(`posts/post/comments/${String(n).padStart(4, '0')}`, { authorUid: 'a' }, CLOCK - 1000);
  h.db.put('posts/post/comments/z-old', { authorUid: 'c' }, CLOCK - 1000);
  h.db.put('posts/post/comments/new', { authorUid: 'b' });
  await h.backend.comment({ postId: 'post', commentId: 'new' });
  assert.deepEqual(h.sent.map(x => x.data.recipientUid).sort(), ['a', 'c']);
});

test('hidden posts, deleted parents and removed or forged likes cannot notify', async () => {
  const h = setup();
  h.db.put('posts/post', { status: 'hidden', authorUid: 'b' });
  h.db.put('posts/post/comments/new', { authorUid: 'a' });
  await h.backend.comment({ postId: 'post', commentId: 'new' });
  h.db.put('posts/post', { status: 'published', authorUid: 'b' });
  h.db.put('posts/post/comments/new', { authorUid: 'a', parentId: 'deleted' });
  await h.backend.comment({ postId: 'post', commentId: 'new' });
  await h.backend.reaction({ postId: 'post', actorUid: 'a' });
  h.db.put('posts/post/likes/a', { uid: 'c' });
  await h.backend.reaction({ postId: 'post', actorUid: 'a' });
  assert.equal(h.sent.length, 0);
});

test('actual reaction notifies author once and matches the existing client notice ID', async () => {
  const h = setup();
  h.db.put('posts/post', { status: 'published', authorUid: 'b' });
  h.db.put('posts/post/likes/a', { uid: 'a' });
  await h.backend.reaction({ postId: 'post', actorUid: 'a' });
  await h.backend.reaction({ postId: 'post', actorUid: 'a' });
  assert.equal(h.sent.length, 1);
  assert.equal(h.db.snap('users/b/notifications/reaction-post-post-a').data().type, 'post_like');
});

test('emulator mode can create in-app notices but never invokes FCM', async () => {
  const h = setup();
  h.db.put('posts/post', { status: 'published', authorUid: 'b' });
  h.db.put('posts/post/comments/new', { authorUid: 'a' });
  const backend = createPushBackend({ ...h, now: () => CLOCK, sendEnabled: () => false });
  await backend.comment({ postId: 'post', commentId: 'new' });
  assert.ok(h.db.snap('users/b/notifications/comment-new').exists);
  assert.equal(h.sent.length, 0);
});

function pendingFriend(h, created = CLOCK) {
  h.db.put('users/b/friend_requests/a', {
    fromUid: 'a', fromName: 'FORGED NAME', fromPhoto: 'FORGED PHOTO', status: 'pending', createdAt: new Date(CLOCK),
  }, created);
  h.db.put('users/a/friend_requests_sent/b', { toUid: 'b', status: 'pending', createdAt: new Date(CLOCK) }, created);
  return { recipientUid: 'b', actorUid: 'a', sourceCreateTime: h.db.snap('users/b/friend_requests/a').createTime };
}

function acceptedFriend(h, created = CLOCK) {
  h.db.put('users/a/friends/b', { uid: 'b', acceptedByUid: 'b', createdAt: new Date(CLOCK) }, created);
  h.db.put('users/b/friends/a', { uid: 'a', acceptedByUid: 'b', createdAt: new Date(CLOCK) }, created);
  return { recipientUid: 'a', actorUid: 'b', sourceCreateTime: h.db.snap('users/a/friends/b').createTime };
}

function publicMeeting(h, created = CLOCK) {
  h.db.put('meets/regional', { admin: 'a', type: 'групповая', users: ['a'], country: 'Serbia', region: 'Belgrade' }, created);
  h.db.put('users/a', { ...h.db.snap('users/a').data(), country: 'Serbia', region: 'Belgrade' });
  h.db.put('users/b', { ...h.db.snap('users/b').data(), country: 'Serbia', region: 'Belgrade' });
  h.db.put('users/c', { ...h.db.snap('users/c').data(), country: 'Serbia', region: 'Novi Sad' });
  h.db.put('users/d', { ...h.db.snap('users/d').data(), country: 'Other country', region: 'Belgrade' });
  const source = h.db.snap('meets/regional');
  return { entityId: 'regional', sourceCreateTime: source.createTime, sourceData: source.data() };
}

test('friend request uses trusted profile, stable destination and one delivery for concurrent retries', async () => {
  const h = setup(), input = pendingFriend(h);
  await Promise.all(Array.from({ length: 8 }, () => h.backend.friendRequest(input)));
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].data.recipientUid, 'b');
  assert.deepEqual(JSON.parse(h.sent[0].data.payload), { kind: 'social', notificationId: 'friend-request-a', recipientUid: 'b' });
  const ref = h.db.doc('users/b/notifications/friend-request-a');
  const notice = (await ref.get()).data();
  assert.equal(notice.type, 'friend_request');
  assert.equal(notice.entityId, 'a');
  assert.equal(notice.actorName, 'a');
  assert.equal(JSON.stringify(notice).includes('FORGED'), false);
  await ref.update({ read: true });
  await h.backend.friendRequest(input);
  assert.equal(h.db.snap(ref.path).data().read, true);
  assert.equal(h.sent.length, 1);
});

test('cancel then recreate friend request within one millisecond gets a new delivery and rejects old generation', async () => {
  const h = setup();
  const firstTime = { seconds: Math.floor(CLOCK / 1000), nanoseconds: 1 };
  const nextTime = { seconds: Math.floor(CLOCK / 1000), nanoseconds: 2 };
  const first = pendingFriend(h, firstTime);
  await h.backend.friendRequest(first);
  await h.db.doc('users/b/notifications/friend-request-a').update({ read: true });
  await h.db.doc('users/b/friend_requests/a').delete();
  await h.db.doc('users/a/friend_requests_sent/b').delete();
  const next = pendingFriend(h, nextTime);
  await h.backend.friendRequest(first);
  assert.equal(h.sent.length, 1);
  assert.equal(h.db.snap('users/b/notifications/friend-request-a').data().read, true);
  await h.backend.friendRequest(next);
  assert.equal(h.sent.length, 2);
  const newer = h.db.snap('users/b/notifications/friend-request-a').data();
  assert.equal(newer.read, false);
  assert.equal(newer.sourceCreatedAt.nanoseconds, 2);
  await h.db.doc('users/b/notifications/friend-request-a').update({ read: true });
  await h.backend.friendRequest(first);
  assert.equal(h.db.snap('users/b/notifications/friend-request-a').data().sourceCreatedAt.nanoseconds, 2);
  assert.equal(h.db.snap('users/b/notifications/friend-request-a').data().read, true);
});

test('friend request refuses canceled, forged, unmatched, expired and unavailable account events', async () => {
  const cases = [
    async h => h.db.doc('users/b/friend_requests/a').delete(),
    async h => h.db.doc('users/a/friend_requests_sent/b').delete(),
    async h => h.db.doc('users/b/friend_requests/a').update({ fromUid: 'c' }),
    async h => h.db.doc('users/a/friend_requests_sent/b').update({ toUid: 'c' }),
    async h => h.db.doc('users/b/friend_requests/a').update({ status: 'accepted' }),
    async h => { h.db.put('users/a/friends/b', { uid: 'b' }); },
    async h => { h.disabled.add('a'); },
    async h => { h.db.put('users/b', { status: 'deleted' }); },
    async h => {
      await h.db.doc('users/a/friend_requests_sent/b').delete();
      h.db.put('users/a/friend_requests_sent/b', { toUid: 'b', status: 'pending' }, CLOCK + 1);
    },
  ];
  for (const alter of cases) {
    const h = setup(), input = pendingFriend(h);
    await alter(h); await h.backend.friendRequest(input);
    assert.equal(h.sent.length, 0);
    assert.equal(h.db.snap('users/b/notifications/friend-request-a').exists, false);
  }
  const h = setup(), old = pendingFriend(h, CLOCK - 2 * 86400000);
  await h.backend.friendRequest(old);
  await h.backend.friendRequest({ ...old, sourceCreateTime: undefined });
  assert.equal(h.sent.length, 0);
});

test('friend request canceled between inbox and FCM is rechecked and never delivered', async () => {
  const h = setup(), input = pendingFriend(h); let reads = 0;
  const getUser = h.auth.getUser;
  h.auth.getUser = async uid => {
    if (uid === 'b' && ++reads === 2) await h.db.doc('users/b/friend_requests/a').delete();
    return getUser(uid);
  };
  await h.backend.friendRequest(input);
  assert.equal(h.sent.length, 0);
  assert.equal([...h.db.docs].find(([path]) => path.startsWith('_push_deliveries/'))[1].data.status, 'skipped');
});

test('acceptance notifies only original requester and preserves read on a repeated event', async () => {
  const h = setup(), input = acceptedFriend(h);
  await Promise.all([
    h.backend.friendAccepted(input),
    h.backend.friendAccepted({ recipientUid: 'b', actorUid: 'a', sourceCreateTime: input.sourceCreateTime }),
  ]);
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].data.recipientUid, 'a');
  const ref = h.db.doc('users/a/notifications/friend-accepted-b');
  assert.equal((await ref.get()).data().type, 'friend_accepted');
  assert.equal((await ref.get()).data().actorUid, 'b');
  assert.deepEqual(JSON.parse(h.sent[0].data.payload), { kind: 'social', notificationId: 'friend-accepted-b', recipientUid: 'a' });
  await ref.update({ read: true }); await h.backend.friendAccepted(input);
  assert.equal((await ref.get()).data().read, true);
  assert.equal(h.sent.length, 1);
});

test('legacy, asymmetric, forged and removed friendships do not prove acceptance', async () => {
  const cases = [
    async h => h.db.doc('users/a/friends/b').update({ acceptedByUid: undefined }),
    async h => h.db.doc('users/b/friends/a').update({ acceptedByUid: 'a' }),
    async h => h.db.doc('users/a/friends/b').update({ uid: 'c' }),
    async h => h.db.doc('users/b/friends/a').delete(),
    async h => { h.disabled.add('b'); },
    async h => {
      await h.db.doc('users/b/friends/a').delete();
      h.db.put('users/b/friends/a', { uid: 'a', acceptedByUid: 'b' }, CLOCK + 1);
    },
  ];
  for (const alter of cases) {
    const h = setup(), input = acceptedFriend(h);
    await alter(h); await h.backend.friendAccepted(input);
    assert.equal(h.sent.length, 0);
    assert.equal(h.db.snap('users/a/notifications/friend-accepted-b').exists, false);
  }
});

test('removing then accepting a new friendship cannot replay an old acceptance generation', async () => {
  const h = setup(), first = acceptedFriend(h);
  await h.backend.friendAccepted(first);
  await h.db.doc('users/a/notifications/friend-accepted-b').update({ read: true });
  await h.db.doc('users/a/friends/b').delete(); await h.db.doc('users/b/friends/a').delete();
  const next = acceptedFriend(h, CLOCK + 1);
  await h.backend.friendAccepted(first); assert.equal(h.sent.length, 1);
  await h.backend.friendAccepted(next); assert.equal(h.sent.length, 2);
  assert.equal(h.db.snap('users/a/notifications/friend-accepted-b').data().read, false);
});

test('public new meeting addresses exact country and region using the existing safe client destination', async () => {
  const h = setup(), input = publicMeeting(h);
  h.user('blocked'); h.disabled.add('blocked');
  h.db.put('users/blocked', { status: 'active', country: 'Serbia', region: 'Belgrade' });
  h.user('deleted'); h.db.put('users/deleted', { status: 'deleted', country: 'Serbia', region: 'Belgrade' });
  h.user('unfinished'); h.db.put('users/unfinished', { isRegistrationEnd: false, country: 'Serbia', region: 'Belgrade' });
  const concurrent = await Promise.allSettled([h.backend.newMeeting(input), h.backend.newMeeting(input)]);
  assert.equal(concurrent.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(concurrent.find(result => result.status === 'rejected').reason.status, 503);
  assert.equal(h.sent.length, 1);
  assert.deepEqual(JSON.parse(h.sent[0].data.payload), { kind: 'new_meeting', isChat: false, groupId: 'regional', recipientUid: 'b' });
  const notice = h.db.snap('users/b/notifications/new-meeting-regional').data();
  assert.equal(notice.type, 'meeting'); assert.equal(notice.kind, 'regional'); assert.equal(notice.entityId, 'regional');
  await h.db.doc('users/b/notifications/new-meeting-regional').update({ read: true });
  await h.backend.newMeeting(input);
  assert.equal(h.db.snap('users/b/notifications/new-meeting-regional').data().read, true);
  assert.equal(h.sent.length, 1);
});

test('private, moved, removed, stale and invalid meeting creation events cannot fan out', async () => {
  const cases = [
    async (h, input) => {
      await h.db.doc('meets/regional').update({ type: 'индивидуальная', invitedUid: 'b' });
      input.sourceData = h.db.snap('meets/regional').data();
    },
    async h => h.db.doc('meets/regional').update({ type: 'индивидуальная', invitedUid: 'b' }),
    async h => h.db.doc('meets/regional').update({ region: 'Novi Sad' }),
    async h => h.db.doc('meets/regional').delete(),
    async h => h.db.doc('meets/regional').update({ users: [] }),
    async h => { h.disabled.add('a'); },
    async (h, input) => { input.sourceCreateTime = undefined; },
    async (h, input) => { input.sourceData = undefined; },
    async (h, input) => {
      await h.db.doc('meets/regional').delete();
      h.db.put('meets/regional', input.sourceData, CLOCK + 1);
    },
  ];
  for (const alter of cases) {
    const h = setup(), input = publicMeeting(h);
    await alter(h, input); await h.backend.newMeeting(input);
    assert.equal(h.sent.length, 0);
    assert.equal(h.db.snap('users/b/notifications/new-meeting-regional').exists, false);
  }
  const h = setup(), old = publicMeeting(h, CLOCK - 2 * 86400000);
  await h.backend.newMeeting(old); assert.equal(h.sent.length, 0);
});

test('regional meeting rechecks recipient region and meeting visibility immediately before FCM', async () => {
  for (const alter of [
    async h => h.db.doc('users/b').update({ region: 'Novi Sad' }),
    async h => h.db.doc('meets/regional').update({ type: 'индивидуальная' }),
  ]) {
    const h = setup(), input = publicMeeting(h); let reads = 0;
    const getUser = h.auth.getUser;
    h.auth.getUser = async uid => {
      if (uid === 'b' && ++reads === 2) await alter(h);
      return getUser(uid);
    };
    await h.backend.newMeeting(input);
    assert.equal(h.sent.length, 0);
    assert.equal([...h.db.docs].find(([path]) => path.startsWith('_push_deliveries/'))[1].data.status, 'skipped');
  }
});

test('regional meeting fanout continues past a bounded page and retries without sending twice', async () => {
  const h = setup(), input = publicMeeting(h), controller = new AbortController();
  for (let n = 0; n < 251; n++) {
    const uid = `regional-${String(n).padStart(3, '0')}`;
    h.user(uid);
    h.db.put(`users/${uid}`, { status: 'active', country: 'Serbia', region: 'Belgrade' });
  }
  const send = h.messaging.send;
  h.messaging.send = async value => {
    await send(value);
    if (h.sent.length === 250) controller.abort();
  };
  await assert.rejects(h.backend.newMeeting({ ...input, signal: controller.signal }), error => error.status === 503);
  assert.equal(h.sent.length, 250);
  const afterUid = fanout(h)[0][1].data.afterUid;
  assert.equal(afterUid, 'regional-247');
  const queryIndex = h.db.queryReads.length;
  h.messaging.send = send;
  await h.backend.newMeeting(input);
  assert.equal(h.db.queryReads.slice(queryIndex).find(query => query.path === 'users').after, afterUid);
  assert.equal(h.sent.length, 252);
  assert.ok(h.sent.some(push => push.data.recipientUid === 'regional-250'));
  await h.backend.newMeeting(input);
  assert.equal(h.sent.length, 252);
});

const fanout = h => [...h.db.docs].filter(([path]) => path.startsWith('_push_fanouts/'));

test('regional cursor resumes after interruption and tolerates deletion of the last processed profile', async () => {
  const h = setup(), input = publicMeeting(h), controller = new AbortController();
  h.db.put('users/c', { status: 'active', country: 'Serbia', region: 'Belgrade' });
  h.db.put('users/d', { status: 'active', country: 'Serbia', region: 'Belgrade' });
  const send = h.messaging.send;
  h.messaging.send = async value => {
    await send(value);
    if (h.sent.length === 2) controller.abort();
  };
  await assert.rejects(h.backend.newMeeting({ ...input, signal: controller.signal }), error => error.status === 503);
  const cursor = fanout(h)[0][1].data;
  assert.equal(cursor.afterUid, 'b');
  assert.equal(cursor.completed, false);
  assert.equal(cursor.leaseOwner, null);
  assert.equal(JSON.stringify(cursor).includes('token'), false);
  assert.equal(JSON.stringify(cursor).includes('actorName'), false);
  await h.db.doc('users/b').delete();
  h.messaging.send = send;
  await h.backend.newMeeting(input);
  assert.deepEqual(h.sent.map(value => value.data.recipientUid), ['b', 'c', 'd']);
  assert.equal(fanout(h)[0][1].data.afterUid, 'd');
  assert.equal(fanout(h)[0][1].data.completed, true);
  await h.backend.newMeeting(input); assert.equal(h.sent.length, 3);
});

test('regional cursor retries a failed checkpoint after FCM without delivering twice', async () => {
  const h = setup(), input = publicMeeting(h);
  const runTransaction = h.db.runTransaction.bind(h.db); let fail = true;
  h.db.runTransaction = run => runTransaction(tx => run({ ...tx, set: (ref, data) => {
    if (fail && ref.path.startsWith('_push_fanouts/') && data.afterUid === 'b') {
      fail = false; throw new Error('checkpoint unavailable');
    }
    tx.set(ref, data);
  } }));
  await assert.rejects(h.backend.newMeeting(input), /checkpoint unavailable/);
  assert.equal(h.sent.length, 1);
  assert.equal(fanout(h)[0][1].data.afterUid, 'a');
  assert.equal(fanout(h)[0][1].data.completed, false);
  await h.backend.newMeeting(input);
  assert.equal(h.sent.length, 1);
  assert.equal(fanout(h)[0][1].data.afterUid, 'b');
  assert.equal(fanout(h)[0][1].data.completed, true);
});

test('regional lease contention is retryable and cannot checkpoint another worker pending delivery', async () => {
  const h = setup(), input = publicMeeting(h); let entered, release, reads = 0;
  const pending = new Promise((resolve, reject) => { release = reject; });
  const waiting = new Promise(resolve => { entered = resolve; });
  const getUser = h.auth.getUser;
  h.auth.getUser = async uid => {
    if (uid === 'b' && ++reads === 2) { entered(); await pending; }
    return getUser(uid);
  };
  const first = h.backend.newMeeting(input);
  const firstResult = first.then(() => null, error => error);
  await waiting;
  await assert.rejects(h.backend.newMeeting(input), error => error.status === 503);
  assert.equal(fanout(h)[0][1].data.afterUid, 'a');
  assert.equal(h.sent.length, 0);
  release(new Error('auth temporarily unavailable'));
  assert.match((await firstResult).message, /auth temporarily unavailable/);
  assert.equal([...h.db.docs].filter(([path]) => path.startsWith('_push_deliveries/')).length, 0);
  h.auth.getUser = getUser;
  await h.backend.newMeeting(input);
  assert.equal(h.sent.length, 1);
  assert.equal(fanout(h)[0][1].data.completed, true);
});

test('regional expired lease fences aborted slow SDK success and failure from a replacement worker', async () => {
  for (const rejectOld of [false, true]) {
    const h = setup(), input = publicMeeting(h), controller = new AbortController();
    let clock = CLOCK, entered, release, reads = 0;
    const pending = new Promise((resolve, reject) => { release = rejectOld ? reject : resolve; });
    const waiting = new Promise(resolve => { entered = resolve; });
    const getUser = h.auth.getUser;
    h.auth.getUser = async uid => {
      if (uid === 'b' && ++reads === 2) { entered(); await pending; }
      return getUser(uid);
    };
    const backend = createPushBackend({ ...h, now: () => clock, timestamp: () => new Date(clock) });
    const old = backend.newMeeting({ ...input, signal: controller.signal }).then(() => null, error => error);
    await waiting;
    clock += 120001;
    controller.abort();
    await backend.newMeeting(input);
    assert.equal(h.sent.length, 1);
    assert.equal(fanout(h)[0][1].data.completed, true);
    release(rejectOld ? new Error('late old SDK failure') : undefined);
    assert.ok(await old);
    assert.equal(h.sent.length, 1);
    assert.equal(fanout(h)[0][1].data.completed, true);
    const delivery = [...h.db.docs].find(([path]) => path.startsWith('_push_deliveries/'))[1].data;
    assert.equal(delivery.status, 'sent');
  }
});

test('regional continuation rejects moved meetings and isolates a recreated meeting generation', async () => {
  for (const recreate of [false, true]) {
    const h = setup(), input = publicMeeting(h), controller = new AbortController();
    h.db.put('users/c', { status: 'active', country: 'Serbia', region: 'Belgrade' });
    const send = h.messaging.send;
    h.messaging.send = async value => { await send(value); controller.abort(); };
    await assert.rejects(h.backend.newMeeting({ ...input, signal: controller.signal }), error => error.status === 503);
    const [originalPath] = fanout(h)[0];
    const before = h.db.snap(originalPath).data();
    h.messaging.send = send;
    if (recreate) {
      await h.db.doc('meets/regional').delete();
      h.db.put('meets/regional', input.sourceData, CLOCK + 1);
    } else await h.db.doc('meets/regional').update({ region: 'Novi Sad' });
    await h.backend.newMeeting(input);
    assert.equal(h.sent.length, 1);
    assert.equal(h.db.snap(originalPath).data().afterUid, before.afterUid);
    assert.equal(h.db.snap(originalPath).data().completed, false);
    if (recreate) {
      const source = h.db.snap('meets/regional');
      await h.backend.newMeeting({ ...input, sourceCreateTime: source.createTime, sourceData: source.data() });
      assert.equal(fanout(h).length, 2);
      assert.deepEqual(h.sent.map(value => value.data.recipientUid), ['b', 'b', 'c']);
      assert.equal(h.db.snap(originalPath).data().completed, false);
      assert.equal(fanout(h).find(([path]) => path !== originalPath)[1].data.completed, true);
    }
  }
});

test('new social events keep inboxes but never deliver FCM when sending is disabled', async () => {
  const h = setup(), request = pendingFriend(h), accepted = acceptedFriend(h), meeting = publicMeeting(h);
  // Remove the accepted pair first so it does not suppress the pending event.
  await h.db.doc('users/a/friends/b').delete(); await h.db.doc('users/b/friends/a').delete();
  const backend = createPushBackend({ ...h, now: () => CLOCK, sendEnabled: () => false });
  await backend.friendRequest(request);
  assert.ok(h.db.snap('users/b/notifications/friend-request-a').exists);
  acceptedFriend(h); await backend.friendAccepted(accepted);
  assert.ok(h.db.snap('users/a/notifications/friend-accepted-b').exists);
  await backend.newMeeting(meeting);
  assert.ok(h.db.snap('users/b/notifications/new-meeting-regional').exists);
  assert.equal(h.sent.length, 0);
});
