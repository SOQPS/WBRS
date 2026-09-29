#!/usr/bin/env node
import { readFile, open, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { collectManifest } from './manifest.mjs';
import { createAuthRestAdapter } from './auth-rest.mjs';

function options(args) {
  const values = {};
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === '--confirm-read-cost') { values.confirm = true; continue; }
    if (!arg.startsWith('--') || !args[index + 1]) throw new Error('Invalid argument');
    values[arg.slice(2)] = args[++index];
  }
  for (const name of ['project', 'bucket', 'key-file', 'out',
    'max-auth-users', 'max-auth-list-pages', 'max-documents', 'max-objects']) {
    if (!values[name]) throw new Error(`Missing --${name}`);
  }
  if (!values.confirm) throw new Error('Specify --confirm-read-cost after reviewing expected reads');
  return values;
}

async function main() {
  const values = options(process.argv.slice(2));
  const keyPath = resolve(values['key-file']);
  const outputPath = resolve(values.out);
  if (keyPath === outputPath) throw new Error('Output cannot replace the HMAC key');
  const keyStat = await stat(keyPath);
  if ((keyStat.mode & 0o077) !== 0) throw new Error('HMAC key file must have mode 0600');
  const key = await readFile(keyPath);
  // Load Firebase SDK only for the live CLI. Unit tests never need credentials.
  const [{ initializeApp, applicationDefault }, { getFirestore },
    { getStorage }] = await Promise.all([
    import('firebase-admin/app'), import('firebase-admin/firestore'),
    import('firebase-admin/storage'),
  ]);
  const credential = applicationDefault();
  const app = initializeApp({ credential, projectId: values.project });
  const manifest = await collectManifest({
    auth: createAuthRestAdapter({ credential, projectId: values.project }),
    firestore: getFirestore(app),
    bucket: getStorage(app).bucket(values.bucket), bucketName: values.bucket,
    projectId: values.project, key,
    maxAuthUsers: Number(values['max-auth-users']),
    maxAuthListPages: Number(values['max-auth-list-pages']),
    maxDocuments: Number(values['max-documents']),
    maxObjects: Number(values['max-objects']),
  });
  const handle = await open(outputPath, 'wx', 0o600);
  try { await handle.writeFile(`${JSON.stringify(manifest, null, 2)}\n`); }
  finally { await handle.close(); }
  process.stdout.write(`Manifest saved. Auth ${manifest.auth.count}; documents ${manifest.firestore.count}; objects ${manifest.storage.count}; bytes ${manifest.storage.bytes}.\n`);
}

main().catch(() => {
  // SDK errors can include request context. Never print them on shared logs.
  process.stderr.write('Inventory failed. Check local permissions and input paths.\n');
  process.exitCode = 1;
});
