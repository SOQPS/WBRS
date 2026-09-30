#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EncryptedArchiveWriter } from './encrypted-archive.mjs';
import { exportFirebase } from './export-core.mjs';
import { validateExportPaths } from './export-paths.mjs';
import { createAuthRestAdapter } from './auth-rest.mjs';

export function parseArgs(args) {
  const values = {};
  const boolean = new Set(['confirm-read-cost']);
  for (let i = 0; i < args.length; i++) {
    const name = args[i].startsWith('--') ? args[i].slice(2) : '';
    if (!name || values[name] !== undefined) throw new Error('Invalid or repeated option');
    if (boolean.has(name)) values[name] = true;
    else if (args[i + 1] && !args[i + 1].startsWith('--')) values[name] = args[++i];
    else throw new Error('Option value missing');
  }
  const expected = new Set([
    'project', 'database', 'bucket', 'out', 'key-file', 'scope', 'storage-prefix',
    'max-auth-users', 'max-auth-list-pages', 'max-firestore-collections', 'max-firestore-references',
    'max-firestore-list-pages', 'max-storage-objects',
    'max-storage-list-pages', 'max-storage-bytes',
    'confirm-project', 'confirm-bucket', 'confirm-read-cost',
  ]);
  for (const name of Object.keys(values)) {
    if (!expected.has(name)) throw new Error('Unknown option');
  }
  const scope = values.scope ?? 'all';
  if (!['all', 'storage', 'metadata'].includes(scope)
      || (scope !== 'storage' && values['storage-prefix'])) {
    throw new Error('A storage prefix requires --scope storage');
  }
  const required = ['project', 'bucket', 'out', 'key-file', 'max-auth-users',
    'max-auth-list-pages',
    'max-firestore-collections', 'max-firestore-references',
    'max-firestore-list-pages'];
  if (scope !== 'metadata') {
    required.push('max-storage-objects', 'max-storage-list-pages', 'max-storage-bytes');
  }
  for (const name of required) {
    if (!values[name]) throw new Error(`Missing --${name}`);
  }
  if (values['confirm-project'] !== values.project
      || values['confirm-bucket'] !== values.bucket
      || values['confirm-read-cost'] !== true) {
    throw new Error('Explicit project, bucket and read-cost confirmation required');
  }
  if (!/^[a-z][a-z0-9-]{4,62}$/.test(values.project)
      || !/^[a-z0-9][a-z0-9._-]{1,220}$/.test(values.bucket)) {
    throw new Error('Invalid project or bucket name');
  }
  const limits = {};
  for (const [flag, label] of [
    ['max-auth-users', 'maxAuthUsers'],
    ['max-auth-list-pages', 'maxAuthListPages'],
    ['max-firestore-collections', 'maxFirestoreCollections'],
    ['max-firestore-references', 'maxFirestoreReferences'],
    ['max-firestore-list-pages', 'maxFirestoreListPages'],
    ['max-storage-objects', 'maxStorageObjects'],
    ['max-storage-list-pages', 'maxStorageListPages'],
    ['max-storage-bytes', 'maxStorageBytes'],
  ]) {
    if (values[flag] === undefined && scope === 'metadata'
        && ['max-storage-objects', 'max-storage-list-pages', 'max-storage-bytes'].includes(flag)) {
      continue;
    }
    if (!/^[1-9][0-9]*$/.test(values[flag])) throw new Error(`Invalid --${flag}`);
    limits[label] = Number(values[flag]);
    if (!Number.isSafeInteger(limits[label])) throw new Error(`Invalid --${flag}`);
  }
  return { values, limits, scope };
}

function pathSegments(path) {
  return path.split('/').map(encodeURIComponent).join('/');
}

export function firestoreApi(credential, project, database, fetchImpl = fetch) {
  const resource = `projects/${project}/databases/${encodeURIComponent(database)}/documents`;
  const endpoint = `https://firestore.googleapis.com/v1/${resource}`;
  async function request(url, options) {
    const token = await credential.getAccessToken();
    const headers = {
      Authorization: `Bearer ${token.access_token}`,
      ...(options?.body ? { 'Content-Type': 'application/json' } : {}),
    };
    const quotaProject = credential.getQuotaProjectId?.();
    if (quotaProject) {
      if (!/^[a-z][a-z0-9-]{4,62}$/.test(quotaProject)) {
        throw new Error('Invalid Firestore quota project');
      }
      headers['x-goog-user-project'] = quotaProject;
    }
    const response = await fetchImpl(url, {
      ...options,
      headers,
      signal: AbortSignal.timeout(30000),
    });
    if (!response.ok) throw new Error(`Firestore read failed (HTTP ${response.status})`);
    return response.json();
  }
  return {
    async listCollectionIds(parent, pageToken) {
      const path = parent ? `/${pathSegments(parent)}` : '';
      const body = { pageSize: 25, ...(pageToken ? { pageToken } : {}) };
      const result = await request(`${endpoint}${path}:listCollectionIds`, {
        method: 'POST', body: JSON.stringify(body),
      });
      return { collectionIds: result.collectionIds ?? [], nextPageToken: result.nextPageToken };
    },
    async listDocuments(collectionPath, pageToken) {
      const url = new URL(`${endpoint}/${pathSegments(collectionPath)}`);
      url.searchParams.set('showMissing', 'true');
      url.searchParams.set('pageSize', '25');
      if (pageToken) url.searchParams.set('pageToken', pageToken);
      const result = await request(url, { method: 'GET' });
      return { documents: result.documents ?? [], nextPageToken: result.nextPageToken };
    },
  };
}

async function main() {
  const { values, limits, scope } = parseArgs(process.argv.slice(2));
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const { output, keyFile } = await validateExportPaths(
    repoRoot, values.out, values['key-file'],
  );
  const key = await readFile(keyFile);
  if (key.length !== 32) throw new Error('Key must contain 32 random bytes');

  // SDK imports happen only after all local guards and confirmations pass.
  const [{ initializeApp, applicationDefault, deleteApp }, storageSdk] = await Promise.all([
    import('firebase-admin/app'),
    scope === 'metadata' ? Promise.resolve(null) : import('firebase-admin/storage'),
  ]);
  const credential = applicationDefault();
  const app = storageSdk ? initializeApp({ credential, projectId: values.project }) : null;
  let writer;
  try {
    writer = await EncryptedArchiveWriter.create(output, key);
    const summary = await exportFirebase({
      auth: createAuthRestAdapter({ credential, projectId: values.project }),
      firestoreApi: firestoreApi(credential, values.project, values.database ?? '(default)'),
      bucket: storageSdk?.getStorage(app).bucket(values.bucket), writer,
      project: values.project, database: values.database ?? '(default)',
      bucketName: values.bucket, scope,
      storagePrefix: values['storage-prefix'] ?? '', limits,
    });
    const label = scope === 'metadata'
      ? 'Encrypted partial metadata export complete'
      : 'Encrypted export complete';
    process.stdout.write(`${label}: ${summary.authUsers} Auth users, `
      + `${summary.firestoreDocuments} documents, ${summary.storageObjects} objects, `
      + `${summary.storageBytes} object bytes.\n`);
  } finally {
    if (writer) await writer.abort();
    if (app) await deleteApp(app);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => {
    // SDK exceptions may contain private paths and data. Print no exception text.
    process.stderr.write('Export failed; archive publication was not confirmed.\n');
    process.exitCode = 1;
  });
}
