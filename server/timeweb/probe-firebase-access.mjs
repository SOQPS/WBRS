#!/usr/bin/env node
// Bounded, read-only IAM probe. Never prints access tokens or user data.
import { execFileSync } from 'node:child_process';

const project = 'chatapp-4e347';
const bucket = 'chatapp-4e347.appspot.com';

let token;
try {
  token = execFileSync('gcloud', ['auth', 'application-default',
    'print-access-token'], { encoding: 'utf8', timeout: 15000,
    stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 8192 }).trim();
  if (!token) throw new Error('empty credential');
} catch {
  process.stderr.write('Application Default Credentials unavailable.\n');
  process.exit(1);
}

const probes = [
  ['project', `https://cloudresourcemanager.googleapis.com/v1/projects/${project}`],
  ['auth', `https://identitytoolkit.googleapis.com/v1/projects/${project}/accounts:batchGet?maxResults=1`],
  ['firestore', `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents:listCollectionIds`, 'POST', '{"pageSize":1}'],
  ['storage', `https://storage.googleapis.com/storage/v1/b/${bucket}/o?maxResults=1`],
];

let failed = false;
for (const [service, url, method = 'GET', body] of probes) {
  try {
    const response = await fetch(url, {
      method, body, signal: AbortSignal.timeout(15000),
      headers: {
        authorization: `Bearer ${token}`,
        'x-goog-user-project': project,
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
    });
    if (response.ok) {
      // Successful bodies may contain private records; never read or print them.
      await response.body?.cancel();
      process.stdout.write(`${service}: HTTP ${response.status}\n`);
      continue;
    }
    failed = true;
    let detail = '';
    try {
      const errorBody = await response.text();
      const error = JSON.parse(errorBody)?.error;
      const reason = error?.details?.find((item) =>
        typeof item?.reason === 'string')?.reason;
      const metadata = error?.details?.find((item) =>
        item?.metadata && typeof item.metadata === 'object')?.metadata;
      const safeReason = typeof reason === 'string'
        && /^[A-Z][A-Z0-9_]{1,63}$/.test(reason) ? reason : null;
      const safeStatus = typeof error?.status === 'string'
        && /^[A-Z][A-Z0-9_]{1,63}$/.test(error.status) ? error.status : null;
      const safePermission = typeof metadata?.permission === 'string'
        && /^[a-z][a-zA-Z0-9.]{1,127}$/.test(metadata.permission)
        ? metadata.permission : null;
      const safeService = typeof metadata?.service === 'string'
        && /^[a-z0-9.-]{1,127}$/.test(metadata.service)
        ? metadata.service : null;
      const safeConsumer = typeof metadata?.consumer === 'string'
        && /^projects\/[0-9]{1,20}$/.test(metadata.consumer)
        ? metadata.consumer : null;
      const mentionedPermission = /(?:Permission |permission: )['"]?([a-z][a-zA-Z0-9.]{1,127})/.exec(
        String(error?.message ?? ''))?.[1];
      const firestoreDenied = service === 'firestore'
        && /missing or insufficient permissions/i.test(String(error?.message ?? ''))
        ? 'MISSING_OR_INSUFFICIENT_PERMISSIONS' : null;
      detail = [safeReason ?? safeStatus, safePermission, safeService,
        safeConsumer, mentionedPermission, firestoreDenied].filter(Boolean).join(' ');
    } catch {
      // Never log a raw Google error body or request context. Storage errors
      // can use XML rather than JSON, so only the HTTP status is shown.
    }
    process.stdout.write(`${service}: HTTP ${response.status}${detail ? ` ${detail}` : ''}\n`);
  } catch {
    failed = true;
    process.stdout.write(`${service}: network/error\n`);
  }
}
if (failed) process.exitCode = 1;
