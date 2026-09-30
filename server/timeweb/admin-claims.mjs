#!/usr/bin/env node
// Narrow Firebase Auth admin-claim change. Dry-run by default. Never store
// credentials or account snapshots in this repository.
import { applicationDefault } from 'firebase-admin/app';
import { readFile, lstat, open } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const PROJECT_RE = /^[a-z][a-z0-9-]{4,62}$/;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const API = 'https://identitytoolkit.googleapis.com/v1/projects';

export function parseClaims(raw) {
  if (raw === undefined || raw === '') return {};
  let claims;
  try { claims = JSON.parse(raw); } catch { throw new Error('Invalid custom claims'); }
  if (!claims || typeof claims !== 'object' || Array.isArray(claims)) {
    throw new Error('Invalid custom claims');
  }
  return claims;
}

export function changedClaims(original, action) {
  const result = { ...original };
  if (action === 'grant') result.admin = true;
  else if (action === 'revoke') delete result.admin;
  else throw new Error('Unknown action');
  if (Buffer.byteLength(JSON.stringify(result), 'utf8') > 1000) {
    throw new Error('Custom claims exceed Firebase limit');
  }
  return result;
}

export function parseEmails(content) {
  let emails;
  try { emails = JSON.parse(content); } catch { throw new Error('Invalid emails file'); }
  if (!Array.isArray(emails) || emails.length !== 4 ||
      emails.some((value) => typeof value !== 'string' || !EMAIL_RE.test(value)) ||
      new Set(emails.map((value) => value.toLowerCase())).size !== 4) {
    throw new Error('Emails file must contain four unique addresses');
  }
  return emails.map((value) => value.toLowerCase());
}

function parseArgs(argv) {
  const flags = new Map();
  const booleans = new Set(['--apply', '--allow-unverified']);
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (!flag.startsWith('--') || flags.has(flag)) throw new Error('Invalid arguments');
    if (booleans.has(flag)) flags.set(flag, true);
    else {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error('Invalid arguments');
      flags.set(flag, value);
    }
  }
  const allowed = new Set(['--project', '--action', '--emails-file', '--backup',
    '--apply', '--confirm-project', '--allow-unverified']);
  if ([...flags.keys()].some((key) => !allowed.has(key)) ||
      !PROJECT_RE.test(flags.get('--project') ?? '') ||
      !['grant', 'revoke', 'restore'].includes(flags.get('--action')) ||
      (flags.get('--action') !== 'restore' && !flags.get('--emails-file')) ||
      !flags.get('--backup') ||
      !path.isAbsolute(flags.get('--backup')) ||
      (flags.get('--action') !== 'restore' &&
        !path.isAbsolute(flags.get('--emails-file'))) ||
      (flags.has('--apply') && flags.get('--confirm-project') !== flags.get('--project')) ||
      (flags.has('--allow-unverified') && flags.get('--action') !== 'grant')) {
    throw new Error('Invalid arguments');
  }
  return flags;
}

async function requirePrivatePath(filename, exists = false) {
  if (!path.isAbsolute(filename) || filename === ROOT ||
      filename.startsWith(`${ROOT}${path.sep}`)) {
    throw new Error('Private file must be outside the repository');
  }
  const parent = await lstat(path.dirname(filename));
  if (!parent.isDirectory() || parent.isSymbolicLink() || (parent.mode & 0o077)) {
    throw new Error('Private file parent must be a private directory');
  }
  if (exists) {
    const file = await lstat(filename);
    if (!file.isFile() || file.isSymbolicLink() || (file.mode & 0o077)) {
      throw new Error('Private file permissions must be 0600');
    }
  }
}

async function request(credential, url, method, body) {
  const token = await credential.getAccessToken();
  if (!token?.access_token) throw new Error('Google ADC unavailable');
  const headers = { Authorization: `Bearer ${token.access_token}` };
  const quotaProject = credential.getQuotaProjectId?.();
  if (quotaProject) {
    if (!PROJECT_RE.test(quotaProject)) throw new Error('Invalid quota project');
    headers['x-goog-user-project'] = quotaProject;
  }
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const response = await fetch(url, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  });
  if (response.status === 404 && method === 'GET') return null;
  if (!response.ok) throw new Error(`Firebase ${method} failed (HTTP ${response.status})`);
  try { return await response.json(); }
  catch { throw new Error('Invalid Firebase response'); }
}

async function lookup(credential, project, field, values) {
  const body = await request(credential, `${API}/${project}/accounts:lookup`,
    'POST', { [field]: values });
  if (!body || !Array.isArray(body.users)) throw new Error('Auth accounts missing');
  return body.users;
}

function matchAccount(users, email) {
  const matches = users.filter((user) =>
    typeof user.email === 'string' && user.email.toLowerCase() === email);
  if (matches.length !== 1 || typeof matches[0].localId !== 'string' ||
      !matches[0].localId) throw new Error('Auth identity not unique or missing');
  return matches[0];
}

async function checkProfiles(credential, project, records) {
  const results = await Promise.all(records.map(({ uid }) => request(credential,
    `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents/users/${encodeURIComponent(uid)}`,
    'GET')));
  if (results.some((result) => !result)) throw new Error('One or more profiles are missing');
}

async function readCurrent(credential, project, entry) {
  const users = await lookup(credential, project, 'localId', [entry.uid]);
  return matchAccount(users, entry.email);
}

async function writeBackup(filename, data) {
  await requirePrivatePath(filename);
  const file = await open(filename, 'wx', 0o600);
  try {
    await file.writeFile(`${JSON.stringify(data)}\n`);
    await file.sync();
  } finally { await file.close(); }
}

async function run(argv) {
  const flags = parseArgs(argv);
  const project = flags.get('--project');
  const action = flags.get('--action');
  const backup = path.resolve(flags.get('--backup'));
  const apply = flags.has('--apply');
  const credential = applicationDefault();
  let entries;
  let unverified = 0;
  if (action === 'restore') {
    await requirePrivatePath(backup, true);
    const saved = JSON.parse(await readFile(backup, 'utf8'));
    if (saved.project !== project || !['grant', 'revoke'].includes(saved.action) ||
        !Array.isArray(saved.entries) || saved.entries.length !== 4) {
      throw new Error('Invalid rollback backup');
    }
    entries = saved.entries.map((row) => {
      if (!EMAIL_RE.test(row.email) || typeof row.uid !== 'string' || !row.uid ||
          !row.original || typeof row.original !== 'object' || Array.isArray(row.original) ||
          !row.desired || typeof row.desired !== 'object' || Array.isArray(row.desired)) {
        throw new Error('Invalid rollback backup');
      }
      return row;
    });
    if (new Set(entries.map((row) => row.email)).size !== 4 ||
        new Set(entries.map((row) => row.uid)).size !== 4) {
      throw new Error('Invalid rollback backup');
    }
  } else {
    const emailsFile = path.resolve(flags.get('--emails-file'));
    await requirePrivatePath(emailsFile, true);
    await requirePrivatePath(backup);
    const emails = parseEmails(await readFile(emailsFile, 'utf8'));
    const users = await lookup(credential, project, 'email', emails);
    entries = emails.map((email) => {
      const user = matchAccount(users, email);
      if (user.disabled === true) throw new Error('Disabled Auth account');
      if (user.emailVerified !== true) unverified++;
      const original = parseClaims(user.customAttributes);
      return { email, uid: user.localId, original,
        desired: changedClaims(original, action) };
    });
    await checkProfiles(credential, project, entries);
  }

  const current = await Promise.all(entries.map((row) => readCurrent(credential, project, row)));
  const planned = entries.filter((row, index) => {
    const claims = parseClaims(current[index].customAttributes);
    const before = action === 'restore' ? row.desired : row.original;
    const after = action === 'restore' ? row.original : row.desired;
    if (!isDeepStrictEqual(claims, before) &&
        !(action === 'restore' && isDeepStrictEqual(claims, after))) {
      throw new Error('Auth claims changed since planning/backup');
    }
    return !isDeepStrictEqual(claims, after);
  });
  const verified = action === 'restore' ? 'not rechecked' : `${4 - unverified}/4`;
  process.stdout.write(`Checked 4 Auth accounts${action === 'restore' ? '' : ' and profiles'}; verified email ${verified}; claim updates needed ${planned.length}; action ${action}; ${apply ? 'apply requested' : 'dry-run'}.\n`);
  if (!apply) return;
  if (action === 'grant' && unverified && !flags.has('--allow-unverified')) {
    throw new Error('Unverified email: grant requires account verification');
  }
  if (action !== 'restore') {
    await writeBackup(backup, { version: 1, project, action, entries });
  }
  let completed = 0;
  try {
    for (const row of planned) {
      const latest = await readCurrent(credential, project, row);
      const expected = action === 'restore' ? row.desired : row.original;
      const desired = action === 'restore' ? row.original : row.desired;
      if (!isDeepStrictEqual(parseClaims(latest.customAttributes), expected)) {
        throw new Error('Auth claims changed during update');
      }
      if (action === 'grant' &&
          (latest.disabled === true ||
           (latest.emailVerified !== true && !flags.has('--allow-unverified')))) {
        throw new Error('Auth account changed during update');
      }
      await request(credential, `${API}/${project}/accounts:update`, 'POST',
        { localId: row.uid, customAttributes: JSON.stringify(desired) });
      const updated = await readCurrent(credential, project, row);
      if (!isDeepStrictEqual(parseClaims(updated.customAttributes), desired)) {
        throw new Error('Auth update could not be verified');
      }
      completed++;
    }
  } catch {
    throw new Error(`Update stopped after ${completed} verified changes; use the private backup for rollback`);
  }
  process.stdout.write(`Verified ${completed} Auth claim updates. Users must refresh their ID tokens.\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  run(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
