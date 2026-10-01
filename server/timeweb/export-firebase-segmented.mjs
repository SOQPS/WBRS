#!/usr/bin/env node
import { readFile, mkdir, lstat } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs as parseSingleArgs, ensureStorageHeadroom } from './export-firebase-encrypted.mjs';
import { privateInput } from './import-cli-common.mjs';
import { validateExportPaths } from './export-paths.mjs';
import { classifyExportFailure, exportSegmentedFirebase } from './export-segmented-core.mjs';

export function parseSegmentedArgs(args) {
  const filtered = [];
  let metadataArchive;
  let maxPrefetch = '4';
  const seen = new Set();
  for (let index = 0; index < args.length; index++) {
    const name = args[index];
    if (['--metadata-archive', '--max-storage-prefetch'].includes(name)) {
      if (seen.has(name) || !args[index + 1] || args[index + 1].startsWith('--')) {
        throw new Error('Invalid segmented export option');
      }
      seen.add(name);
      if (name === '--metadata-archive') metadataArchive = args[++index];
      else maxPrefetch = args[++index];
    } else filtered.push(name);
  }
  const parsed = parseSingleArgs(filtered);
  if (!metadataArchive || parsed.scope !== 'all' || !/^[1-4]$/.test(maxPrefetch)) {
    throw new Error('Segmented export requires complete scope and prefetch 1..4');
  }
  return { ...parsed, metadataArchive, maxPrefetch: Number(maxPrefetch),
    limits: { ...parsed.limits, maxObjectBytes: 64_000_000 } };
}

async function main() {
  const { values, limits, metadataArchive, maxPrefetch } = parseSegmentedArgs(process.argv.slice(2));
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const requested = resolve(values.out);
  // Check the already-existing parent outside Git before creating a private
  // shard directory; then apply the same realpath/key guards to the actual index.
  await validateExportPaths(repoRoot, join(dirname(dirname(requested)),
    basename(dirname(requested)) + '.guard'), values['key-file']);
  await mkdir(dirname(requested), { mode: 0o700 }).catch((error) => {
    if (error.code !== 'EEXIST') throw error;
  });
  const directory = await lstat(dirname(requested));
  if (!directory.isDirectory() || (directory.mode & 0o077) !== 0) {
    throw new Error('Shard directory must be private');
  }
  const { output, keyFile } = await validateExportPaths(repoRoot, requested, values['key-file']);
  const metadataPath = await privateInput(metadataArchive, 'Metadata archive');
  const key = await readFile(keyFile);
  if (key.length !== 32) throw new Error('Invalid archive key');
  const [{ initializeApp, applicationDefault, deleteApp }, { getStorage }] = await Promise.all([
    import('firebase-admin/app'), import('firebase-admin/storage'),
  ]);
  const app = initializeApp({ credential: applicationDefault(), projectId: values.project });
  let lastStatus;
  let lastCompleted = -100;
  try {
    const summary = await exportSegmentedFirebase({ metadataArchive: metadataPath,
      outputPath: output, key, source: { project: values.project,
        database: values.database ?? '(default)', bucket: values.bucket },
      bucket: getStorage(app).bucket(values.bucket), limits, maxPrefetch,
      beforeStorageStart: (bytes) => ensureStorageHeadroom(dirname(output), bytes),
      beforeStorageObject: (bytes) => ensureStorageHeadroom(dirname(output), bytes),
      onProgress: async (state) => {
        if (state.status !== lastStatus || state.completed - lastCompleted >= 100) {
          process.stdout.write(JSON.stringify(state) + '\n');
          lastStatus = state.status; lastCompleted = state.completed;
        }
      } });
    process.stdout.write(JSON.stringify({ status: 'sealed_index_complete', summary,
      finalSyncRequired: true }) + '\n');
  } finally { await deleteApp(app); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(JSON.stringify({ status: 'segmented_export_failed',
      errorClassification: classifyExportFailure(error) }) + '\n');
    process.exitCode = 1;
  });
}
