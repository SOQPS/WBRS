import { createHash } from 'node:crypto';

const hash = value => createHash('sha256').update(value).digest('hex');
const validId = value => typeof value === 'string' && value.length > 0 && value.length <= 128 &&
  !/[\/\\\x00-\x1f]/.test(value) && value !== '.' && value !== '..';
const creationTime = user => Date.parse(user?.metadata?.creationTime ?? '');
const validEmail = value => typeof value === 'string' && value.length <= 320 &&
  /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim());
const knownFields = new Set(['uid', 'email', 'authCreatedAtMs', 'authCreateEventHash', 'status']);
const eventHash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const owned = (data, uid) => !Object.hasOwn(data, 'uid') || data.uid === uid;
const deleted = data => data?.status === 'deleted' || data?.deleted === true ||
  (data != null && Object.hasOwn(data, 'deletionRequestedAt'));

export class PrivateEmailError extends Error {
  constructor(code) { super(code); this.code = code; }
}
function check(signal) {
  if (signal?.aborted) throw new PrivateEmailError('private_email_deadline');
}

/** Trusted Auth events only. No client payload can supply this directory email. */
export function createPrivateEmailLifecycle({ db, auth, enabled = () => false, now = () => Date.now() }) {
  async function current(uid, signal) {
    check(signal);
    try {
      const user = await auth.getUser(uid);
      check(signal);
      if (user?.uid !== uid || !Number.isFinite(creationTime(user))) {
        throw new PrivateEmailError('private_email_auth_identity');
      }
      return user;
    } catch (error) {
      check(signal);
      if (error?.code === 'auth/user-not-found') return null;
      if (error instanceof PrivateEmailError) throw error;
      throw new PrivateEmailError('private_email_auth_unavailable');
    }
  }
  function event({ uid, createdAt, eventAt, eventId }) {
    const createdMs = Date.parse(createdAt ?? ''), eventMs = Date.parse(eventAt ?? '');
    return validId(uid) && Number.isFinite(createdMs) && Number.isFinite(eventMs) &&
      createdMs <= eventMs && eventMs <= now() + 60000 &&
      typeof eventId === 'string' && eventId.length > 0 && eventId.length <= 1024 ? createdMs : null;
  }
  async function deletionState(tx, profile, signal) {
    const data = profile.data();
    if (!deleted(data)) return null;
    const stamp = data?.deletionRequestedAt;
    // This is the existing cleanup key, not a new job collection or lease.
    if (Number.isSafeInteger(stamp?.seconds) && Number.isInteger(stamp?.nanoseconds) &&
        stamp.nanoseconds >= 0 && stamp.nanoseconds < 1e9) {
      const ref = db.doc(`_account_cleanup/${hash(`${profile.id}\0${stamp.seconds}:${stamp.nanoseconds}`)}`);
      const job = await tx.get(ref);
      check(signal);
      if (job.data()?.status === 'running' || job.data()?.lockId || job.data()?.leaseUntilMs > now()) {
        return 'cleanup_in_progress';
      }
    }
    return 'deleted_profile';
  }
  async function provision(input) {
    if (!enabled()) return { status: 'disabled' };
    const createdMs = event(input);
    if (createdMs === null) return { status: 'invalid_auth_event' };
    const { uid, signal } = input;
    // Auth SDK creationTime loses milliseconds. A distinct trusted onCreate
    // event must never adopt another event's private record under reused UID.
    const createEventHash = hash(input.eventId);
    const live = await current(uid, signal);
    if (!live) return { status: 'auth_absent' };
    if (creationTime(live) !== createdMs) return { status: 'auth_generation_changed' };
    if (live.disabled) return { status: 'auth_disabled' };
    if (!validEmail(live.email)) return { status: 'auth_email_absent' };
    const profileRef = db.doc(`users/${uid}`), privateRef = db.doc(`private_users/${uid}`);
    return db.runTransaction(async tx => {
      check(signal);
      const [profile, directory] = await Promise.all([tx.get(profileRef), tx.get(privateRef)]);
      check(signal);
      if (profile.exists && !owned(profile.data(), uid)) return { status: 'profile_owner_conflict' };
      const deletion = await deletionState(tx, profile, signal);
      if (deletion) return { status: deletion };
      if (profile.data()?.status === 'blocked') return { status: 'blocked_profile' };
      const data = directory.data();
      if (directory.exists) {
        if (!owned(data, uid) || !Object.keys(data).every(key => knownFields.has(key))) {
          return { status: 'private_owner_conflict' };
        }
        // Permanent UID fence. Never lift it by comparing second-precision Auth
        // creationTime or by silently adopting a privileged recreated account.
        if (data.status === 'auth_deleted') return { status: 'deleted_uid_requires_review' };
        if (data.authCreatedAtMs !== undefined && data.authCreatedAtMs !== createdMs) {
          return { status: 'private_generation_conflict' };
        }
        if (data.authCreatedAtMs === undefined || data.authCreateEventHash === undefined) {
          return { status: 'legacy_private_requires_review' };
        }
        if (!eventHash(data.authCreateEventHash) || data.authCreateEventHash !== createEventHash) {
          return { status: 'private_event_requires_review' };
        }
      }
      const latest = await current(uid, signal);
      if (!latest) return { status: 'auth_absent' };
      if (creationTime(latest) !== createdMs) return { status: 'auth_generation_changed' };
      if (latest.disabled) return { status: 'auth_disabled' };
      if (!validEmail(latest.email)) return { status: 'auth_email_absent' };
      const email = latest.email.trim().toLowerCase();
      if (directory.exists) {
        if (typeof data.email !== 'string' || data.email !== email) return { status: 'private_email_conflict' };
        // Do not adopt or rewrite migrated legacy documents, nor update an
        // existing email from an onCreate retry. Conflicts need owner review.
        return { status: 'already_provisioned' };
      }
      check(signal);
      tx.set(privateRef, { uid, email, authCreatedAtMs: createdMs, authCreateEventHash: createEventHash });
      return { status: 'provisioned' };
    });
  }
  async function remove(input) {
    if (!enabled()) return { status: 'disabled' };
    const createdMs = event(input);
    if (createdMs === null) return { status: 'invalid_auth_event' };
    const { uid, signal } = input;
    // Existing Auth means recreated/still-active UID: never modify its private
    // data, even if SDK timestamps happen to match within the same second.
    if (await current(uid, signal)) return { status: 'auth_uid_exists' };
    const profileRef = db.doc(`users/${uid}`), privateRef = db.doc(`private_users/${uid}`);
    return db.runTransaction(async tx => {
      check(signal);
      const [profile, directory] = await Promise.all([tx.get(profileRef), tx.get(privateRef)]);
      check(signal);
      if (profile.exists && !owned(profile.data(), uid)) return { status: 'profile_owner_conflict' };
      const data = directory.data();
      if (directory.exists) {
        if (!owned(data, uid) || !Object.keys(data).every(key => knownFields.has(key))) {
          return { status: 'private_owner_conflict' };
        }
        if (data.authCreatedAtMs === undefined || data.authCreateEventHash === undefined) {
          // An earlier direct-delete marker may have been created before the
          // delayed onCreate event supplied an event hash. Its fence is final.
          if (data.status === 'auth_deleted' && !Object.hasOwn(data, 'email')) return { status: 'already_fenced' };
          return { status: 'legacy_private_requires_review' };
        }
        if (!eventHash(data.authCreateEventHash)) return { status: 'private_event_requires_review' };
        if (data.authCreatedAtMs !== createdMs) return { status: 'private_generation_conflict' };
      }
      const deletion = await deletionState(tx, profile, signal);
      if (await current(uid, signal)) return { status: 'auth_uid_exists' };
      check(signal);
      if (deletion) {
        // The users tombstone is the persistent fence in normal app deletion.
        if (directory.exists) tx.delete(privateRef);
        return { status: 'tombstone_fenced' };
      }
      if (data?.status === 'auth_deleted' && !Object.hasOwn(data, 'email')) return { status: 'already_fenced' };
      // Console/Auth deletion without a users tombstone must retain this marker.
      // An earlier creator read conflicts and retries against the same document.
      tx.set(privateRef, { uid, authCreatedAtMs: createdMs, status: 'auth_deleted',
        ...(data?.authCreateEventHash ? { authCreateEventHash: data.authCreateEventHash } : {}) });
      return { status: 'deleted_uid_fenced' };
    });
  }
  return { provision, remove };
}

export function createPrivateEmailAuthHandler({ backend, operation, enabled = () => false,
  report = () => {}, deadlineMs = 15000 }) {
  return async (user, context) => {
    if (!enabled()) return { status: 'disabled' };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), deadlineMs);
    try {
      const result = await backend[operation]({ uid: user?.uid,
        createdAt: user?.metadata?.creationTime, eventAt: context?.timestamp,
        eventId: context?.eventId, signal: controller.signal });
      if (/conflict|requires_review/.test(result?.status ?? '')) {
        // Safe codes only: never report email, UID, SDK errors or event payload.
        report({ operation, status: result.status });
      }
      return result;
    } catch (error) {
      throw new Error(error instanceof PrivateEmailError ? error.code : 'private_email_unavailable');
    } finally { clearTimeout(timer); controller.abort(); }
  };
}
