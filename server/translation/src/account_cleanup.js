import { createHash, randomUUID } from 'node:crypto';

const PAGE = 100;
const LEASE_MS = 180000;
const hash = value => createHash('sha256').update(value).digest('hex');
const id = value => typeof value === 'string' && value.length > 0 && value.length <= 128 &&
  !/[\/\\\x00-\x1f]/.test(value) && value !== '.' && value !== '..';

// An explicit allowlist, not a replacement of users/{uid}. In particular,
// balance, gifts, payments, purchased invisibility, roles and unknown fields stay.
export const PROFILE_PERSONAL_FIELDS = Object.freeze([
  'fullName', 'email', 'profilePic', 'profilePicThumb', 'age', 'rost', 'about',
  'hobbi', 'deti', 'temperament', 'city', 'country', 'countryCode',
  'languageGroup', 'countrySegment', 'region', 'images', 'pol',
  'relationStatus', 'группа', 'group', 'language', 'online', 'lastOnlineTS',
  'chatWithId', 'interests', 'testAnswers', 'profileDetailsSaved',
  'isRegistrationEnd', 'registrationNoticePending',
]);
const PUBLIC_FIELDS = new Set(['uid', ...PROFILE_PERSONAL_FIELDS.filter(field =>
  !['email', 'chatWithId', 'interests', 'testAnswers', 'profileDetailsSaved',
    'isRegistrationEnd', 'registrationNoticePending'].includes(field))]);
// Provision metadata contains no email beyond the already-private field.
// Do not allow `status` here: a direct-Auth-delete auth_deleted marker is a
// persistent UID fence and must not be erased by the generic cleanup path.
const PRIVATE_FIELDS = new Set(['uid', 'email', 'authCreatedAtMs', 'authCreateEventHash']);
const TOKEN_FIELDS = new Set(['uid', 'token', 'tokens', 'updatedAt']);
const IMAGE_FIELDS = new Set(['url', 'thumbnailUrl']);
const INBOX_FIELDS = new Set(['type', 'kind', 'title', 'body', 'entityId', 'read',
  'createdAt', 'sourceCreatedAt', 'actorName', 'actorPhoto', 'actorUid', 'rootCommentId']);
const INCOMING_FIELDS = new Set(['fromUid', 'fromName', 'fromPhoto', 'группа', 'createdAt', 'status']);
const SENT_FIELDS = new Set(['toUid', 'toName', 'toPhoto', 'группа', 'createdAt', 'status']);
const allowed = (data, fields) => !!data && Object.keys(data).every(key => fields.has(key));

// Keep nanoseconds when comparing Firestore timestamps. Millisecond rounding
// must not admit a document written just after deletionRequestedAt.
function point(value) {
  if (typeof value?.toMillis !== 'function' || !Number.isSafeInteger(value.seconds) ||
      !Number.isInteger(value.nanoseconds) || value.nanoseconds < 0 || value.nanoseconds >= 1e9) return null;
  return { seconds: value.seconds, nanoseconds: value.nanoseconds };
}
function datePoint(value) {
  const ms = value instanceof Date ? value.getTime() : typeof value === 'string' ? Date.parse(value) : NaN;
  if (!Number.isFinite(ms)) return null;
  const fractional = typeof value === 'string' && value.match(/\.(\d{1,9})Z$/)?.[1];
  return { seconds: Math.floor(ms / 1000),
    nanoseconds: fractional ? Number(fractional.padEnd(9, '0')) : (ms % 1000) * 1e6 };
}
const compare = (a, b) => a.seconds - b.seconds || a.nanoseconds - b.nanoseconds;
const same = (a, b) => !!a && !!b && compare(a, b) === 0;
const old = (snapshot, cutoff) => !!point(snapshot.createTime) && !!point(snapshot.updateTime) &&
  compare(point(snapshot.createTime), cutoff) <= 0 && compare(point(snapshot.updateTime), cutoff) <= 0;
const stampKey = value => `${value.seconds}:${value.nanoseconds}`;

export class AccountCleanupError extends Error {
  constructor(code, retryable = false) { super(code); this.code = code; this.retryable = retryable; }
}
function check(signal) {
  if (signal?.aborted) throw new AccountCleanupError('cleanup_deadline', true);
}

/** Only a trusted Auth onDelete event may call this backend. No client UID endpoint. */
export function createAccountCleanup({ db, auth, bucket, enabled = () => false,
  now = () => Date.now(), timestamp, deleteField, documentId = '__name__' }) {
  async function authAbsent(uid, signal) {
    check(signal);
    try { await auth.getUser(uid); }
    catch (error) {
      check(signal);
      if (error?.code === 'auth/user-not-found') return;
      throw new AccountCleanupError('cleanup_auth_unavailable', true);
    }
    throw new AccountCleanupError('auth_uid_exists');
  }

  async function cleanup({ uid, eventId, deletedAt, createdAt, signal }) {
    if (!enabled()) return { status: 'disabled' };
    const eventTime = datePoint(deletedAt), creationTime = datePoint(createdAt);
    if (!id(uid) || typeof eventId !== 'string' || !eventId || eventId.length > 1024 ||
        !eventTime || !creationTime || compare(creationTime, eventTime) > 0 ||
        eventTime.seconds * 1000 > now() + 60000) return { status: 'invalid_auth_event' };
    if (typeof timestamp !== 'function' || typeof deleteField !== 'function') {
      throw new AccountCleanupError('cleanup_configuration_missing', true);
    }
    const profileRef = db.doc(`users/${uid}`);
    const initial = await profileRef.get();
    const requestedAt = point(initial.data()?.deletionRequestedAt);
    const validTombstone = snapshot => snapshot.exists && snapshot.data()?.status === 'deleted' &&
      (!Object.hasOwn(snapshot.data(), 'uid') || snapshot.data().uid === uid) &&
      same(point(snapshot.data()?.deletionRequestedAt), requestedAt);
    if (!requestedAt || !validTombstone(initial) || compare(creationTime, requestedAt) > 0 ||
        compare(requestedAt, eventTime) > 0) return { status: 'no_matching_tombstone' };
    const jobRef = db.doc(`_account_cleanup/${hash(`${uid}\0${stampKey(requestedAt)}`)}`);
    const lockId = randomUUID();
    const counts = { removedDocuments: 0, removedPhotos: 0, skippedDocuments: 0, skippedPhotos: 0,
      unresolvedPhotoReferences: 0 };
    let claimed = false;
    let storage;
    const unresolvedHashes = new Set();
    let needsLegacyReview = false;
    let photoEvidenceTruncated = false;

    function photoReference(value) {
      if (value === undefined || value === null || value === '') return;
      let objectName;
      if (typeof value === 'string') {
        try {
          const url = new URL(value);
          if (url.protocol === 'https:' && url.hostname === 'firebasestorage.googleapis.com') {
            const match = url.pathname.match(/^\/v0\/b\/([^/]+)\/o\/(.+)$/);
            if (match && decodeURIComponent(match[1]) === storage.name) objectName = decodeURIComponent(match[2]);
          } else if (url.protocol === 'gs:' && url.hostname === storage.name) {
            objectName = decodeURIComponent(url.pathname.slice(1));
          }
        } catch { /* Unknown legacy references are evidence gaps, not deletion targets. */ }
      }
      if (!objectName || ![`users/${uid}/photos/`, `profile_images/${uid}/`]
        .some(prefix => objectName.startsWith(prefix) && objectName !== prefix)) {
        // A bounded digest preserves evidence after personal fields are scrubbed.
        // Queries/fragments may include bearer download tokens: never retain
        // them, even as digest input. Digests cannot prove legacy ownership.
        let evidence = typeof value === 'string' ? value.split(/[?#]/, 1)[0] : 'unknown_photo_schema';
        try { const url = new URL(evidence); evidence = `${url.protocol}//${url.host}${url.pathname}`; } catch {}
        const digest = hash(`${uid}\0${evidence}`);
        needsLegacyReview = true;
        if (!unresolvedHashes.has(digest)) {
          if (unresolvedHashes.size < 100) unresolvedHashes.add(digest);
          else photoEvidenceTruncated = true;
          counts.unresolvedPhotoReferences++;
        }
      }
    }

    async function guard(tx) {
      check(signal);
      const [profile, job] = await Promise.all([tx.get(profileRef), tx.get(jobRef)]);
      if (!validTombstone(profile)) throw new AccountCleanupError('tombstone_changed');
      if (job.data()?.lockId !== lockId || job.data()?.leaseUntilMs <= now()) {
        throw new AccountCleanupError('cleanup_lease_lost', true);
      }
      await authAbsent(uid, signal);
      return profile;
    }

    async function erase(ref, fields, proof = () => true) {
      const result = await db.runTransaction(async tx => {
        await guard(tx);
        const entry = await tx.get(ref);
        if (!entry.exists) return 'missing';
        const data = entry.data();
        if (!old(entry, requestedAt) || !allowed(data, fields) ||
            (Object.hasOwn(data, 'uid') && data.uid !== uid) || !proof(data, entry.id)) return 'skipped';
        // Auth is separate from Firestore; recheck as late as possible. The
        // transaction also conditions deletion on this exact document version.
        await authAbsent(uid, signal);
        if (fields === IMAGE_FIELDS) {
          photoReference(data.url); photoReference(data.thumbnailUrl);
          if (needsLegacyReview) tx.update(jobRef, { needsLegacyReview, photoEvidenceTruncated,
            unresolvedPhotoReferences: counts.unresolvedPhotoReferences,
            unresolvedPhotoReferenceHashes: [...unresolvedHashes] });
        }
        tx.delete(ref);
        return 'removed';
      });
      if (result === 'removed') counts.removedDocuments++;
      if (result === 'skipped') counts.skippedDocuments++;
    }

    async function scan(collection, run) {
      let cursor;
      for (;;) {
        check(signal);
        let query = db.collection(collection).orderBy(documentId).limit(PAGE);
        if (cursor) query = query.startAfter(cursor);
        const page = await query.get();
        for (const entry of page.docs) { check(signal); await run(entry); }
        if (page.size < PAGE) return;
        cursor = page.docs.at(-1);
      }
    }

    async function requestPair(entry, incoming) {
      const peer = entry.id;
      if (!id(peer) || peer === uid) { counts.skippedDocuments++; return; }
      const mirror = db.doc(`users/${peer}/${incoming ? 'friend_requests_sent' : 'friend_requests'}/${uid}`);
      const ownFields = incoming ? INCOMING_FIELDS : SENT_FIELDS;
      const mirrorFields = incoming ? SENT_FIELDS : INCOMING_FIELDS;
      const ownUidField = incoming ? 'fromUid' : 'toUid';
      const mirrorUidField = incoming ? 'toUid' : 'fromUid';
      const results = await db.runTransaction(async tx => {
        await guard(tx);
        const [source, other] = await Promise.all([tx.get(entry.ref), tx.get(mirror)]);
        if (!source.exists) return [];
        if (!old(source, requestedAt) || !allowed(source.data(), ownFields) ||
            source.data()[ownUidField] !== peer) return ['skipped'];
        const mirrorSafe = other.exists && old(other, requestedAt) &&
          allowed(other.data(), mirrorFields) && other.data()[mirrorUidField] === uid &&
          same(point(other.data().createdAt), point(source.data().createdAt)) &&
          source.data().status === 'pending' && other.data().status === 'pending';
        await authAbsent(uid, signal);
        // Keep the counterpart until its UID and the pair's creation stamp
        // prove ownership. Both deletes commit together, so retries keep proof.
        tx.delete(entry.ref);
        if (mirrorSafe) tx.delete(mirror);
        return ['removed', ...(other.exists ? [mirrorSafe ? 'removed' : 'skipped'] : [])];
      });
      counts.removedDocuments += results.filter(result => result === 'removed').length;
      counts.skippedDocuments += results.filter(result => result === 'skipped').length;
    }

    async function photos() {
      for (const prefix of [`users/${uid}/photos/`, `profile_images/${uid}/`]) {
        let pageToken;
        do {
          check(signal);
          await db.runTransaction(guard);
          const [files, next] = await storage.getFiles({ prefix, autoPaginate: false,
            maxResults: PAGE, ...(pageToken ? { pageToken } : {}) });
          for (const file of files) {
            check(signal);
            if (typeof file.name !== 'string' || !file.name.startsWith(prefix) || file.name === prefix) {
              counts.skippedPhotos++; continue;
            }
            let metadata;
            try { [metadata] = await file.getMetadata(); }
            catch (error) { if (Number(error?.code) === 404) continue; throw error; }
            const created = datePoint(metadata.timeCreated), updated = datePoint(metadata.updated);
            if (!created || !updated || compare(created, requestedAt) > 0 || compare(updated, requestedAt) > 0 ||
                !/^\d+$/.test(String(metadata.generation || '')) ||
                !/^\d+$/.test(String(metadata.metageneration || ''))) {
              counts.skippedPhotos++; continue;
            }
            await db.runTransaction(guard);
            check(signal);
            try {
              // Put preconditions on the File constructor, as required by this
              // installed Storage SDK's delete API. Never follow download URLs.
              await storage.file(file.name, { preconditionOpts: {
                ifGenerationMatch: String(metadata.generation),
                ifMetagenerationMatch: String(metadata.metageneration),
              } }).delete({ ignoreNotFound: true });
              counts.removedPhotos++;
            } catch (error) {
              if (Number(error?.code) === 404) continue;
              if (Number(error?.code) === 412) { counts.skippedPhotos++; continue; }
              throw error;
            }
          }
          pageToken = next?.pageToken;
        } while (pageToken);
      }
    }

    async function finish(status) {
      await db.runTransaction(async tx => {
        const job = await tx.get(jobRef);
        if (job.data()?.lockId !== lockId) return;
        tx.update(jobRef, { status, lockId: deleteField(), leaseUntilMs: deleteField(),
          lastAttemptAt: timestamp(), ...counts, needsLegacyReview, photoEvidenceTruncated,
          unresolvedPhotoReferenceHashes: [...unresolvedHashes] });
      });
    }

    try {
      storage = typeof bucket === 'function' ? bucket() : bucket;
      photoReference(initial.data().profilePic); photoReference(initial.data().profilePicThumb);
      if (Array.isArray(initial.data().images)) {
        for (const reference of initial.data().images) photoReference(reference);
      } else if (initial.data().images !== undefined) {
        photoReference(initial.data().images);
      }
      const claim = await db.runTransaction(async tx => {
        const [profile, job] = await Promise.all([tx.get(profileRef), tx.get(jobRef)]);
        if (!validTombstone(profile)) throw new AccountCleanupError('tombstone_changed');
        await authAbsent(uid, signal);
        if (job.data()?.status === 'completed_scope') return 'already_completed';
        if (job.data()?.lockId && job.data().leaseUntilMs > now()) return 'in_progress';
        // Retry must not lose an unresolved legacy-photo gap after an earlier
        // attempt removed the profile's personal reference fields.
        for (const digest of job.data()?.unresolvedPhotoReferenceHashes || []) {
          if (typeof digest === 'string' && /^[a-f0-9]{64}$/.test(digest) && unresolvedHashes.size < 100) {
            unresolvedHashes.add(digest);
          }
        }
        needsLegacyReview ||= job.data()?.needsLegacyReview === true;
        photoEvidenceTruncated ||= job.data()?.photoEvidenceTruncated === true;
        counts.unresolvedPhotoReferences = Math.max(unresolvedHashes.size,
          Number.isSafeInteger(job.data()?.unresolvedPhotoReferences) ? job.data().unresolvedPhotoReferences : 0);
        tx.set(jobRef, { status: 'running', lockId, leaseUntilMs: now() + LEASE_MS,
          deletionRequestedAt: profile.data().deletionRequestedAt,
          authEventHash: hash(eventId), startedAt: timestamp(), needsLegacyReview, photoEvidenceTruncated,
          unresolvedPhotoReferences: counts.unresolvedPhotoReferences,
          unresolvedPhotoReferenceHashes: [...unresolvedHashes] });
        return 'claimed';
      });
      if (claim !== 'claimed') return { status: claim };
      claimed = true;
      await scan(`users/${uid}/images`, entry => erase(entry.ref, IMAGE_FIELDS));
      // "Inbox" in this checkout is users/{uid}/notifications, not a guessed
      // inbox collection. Unknown notification fields are deliberately retained.
      await scan(`users/${uid}/notifications`, entry => erase(entry.ref, INBOX_FIELDS));
      await erase(db.doc(`TOKENS/${uid}`), TOKEN_FIELDS);
      await erase(db.doc(`private_users/${uid}`), PRIVATE_FIELDS);
      await erase(db.doc(`public_profiles/${uid}`), PUBLIC_FIELDS);
      await scan(`users/${uid}/friend_requests`, entry => requestPair(entry, true));
      await scan(`users/${uid}/friend_requests_sent`, entry => requestPair(entry, false));
      await photos();
      await db.runTransaction(async tx => {
        const profile = await guard(tx), patch = {};
        for (const field of PROFILE_PERSONAL_FIELDS) {
          if (Object.hasOwn(profile.data(), field)) patch[field] = deleteField();
        }
        if (Object.keys(patch).length) {
          await authAbsent(uid, signal);
          tx.update(profileRef, patch);
        }
      });
      const status = counts.skippedDocuments || counts.skippedPhotos || needsLegacyReview
        ? 'partial_scope' : 'completed_scope';
      await finish(status);
      return { status, ...counts };
    } catch (error) {
      const safe = error instanceof AccountCleanupError ? error : new AccountCleanupError('cleanup_unavailable', true);
      if (claimed) { try { await finish(safe.retryable ? 'partial' : safe.code); } catch {} }
      if (!safe.retryable) return { status: safe.code, ...counts };
      // Do not expose SDK errors: they may contain private paths or tokens.
      throw safe;
    }
  }
  return { cleanup };
}

export function createAuthDeleteCleanupHandler({ backend, enabled = () => false, deadlineMs = 150000 }) {
  return async (user, context) => {
    if (!enabled()) return { status: 'disabled' };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), deadlineMs);
    try {
      const result = await backend.cleanup({ uid: user?.uid, eventId: context?.eventId,
        deletedAt: context?.timestamp, createdAt: user?.metadata?.creationTime, signal: controller.signal });
      // A crash can leave a live lease without a worker. Acknowledge only a
      // terminal result; failurePolicy retries contention until the lease ends.
      // Otherwise Firebase could ack the only remaining event permanently.
      if (result?.status === 'in_progress') throw new AccountCleanupError('cleanup_in_progress', true);
      return result;
    } catch {
      throw new Error('account_cleanup_unavailable');
    } finally { clearTimeout(timer); controller.abort(); }
  };
}
