#!/usr/bin/env node
import { readFile, realpath, stat } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { dirname, isAbsolute, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { S3Client } from '@aws-sdk/client-s3';
import { createPostgresImportAdapter, createPostgresVerificationAdapter,
  createPrivateS3MediaAdapter } from './import-adapters.mjs';
import { stageImport, verifyStagedImport } from './import-stage.mjs';
import { assertPrivateMediaBucket } from './s3-privacy.mjs';

const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const positiveOptions = new Map([
  ['--max-auth-users', 'maxAuthUsers'],
  ['--max-firestore-documents', 'maxFirestoreDocuments'],
  ['--max-storage-objects', 'maxStorageObjects'],
  ['--max-storage-bytes', 'maxStorageBytes'],
  ['--max-object-bytes', 'maxObjectBytes'],
]);
const namedOptions = new Set([
  '--archive', '--key-file', '--project', '--database', '--bucket',
  '--mode', '--confirm-target-db', '--target-media-bucket',
  '--confirm-private-bucket', '--timeweb-bucket-id', ...positiveOptions.keys(),
]);

function argsMap(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index];
    if (!namedOptions.has(name) || !args[index + 1] || values.has(name)) {
      throw new Error('Invalid import arguments');
    }
    values.set(name, args[index + 1]);
  }
  for (const name of ['--archive', '--key-file', '--project', '--database', '--bucket']) {
    if (!values.has(name)) throw new Error('Missing source confirmation');
  }
  const mode = values.get('--mode') ?? 'dry-run';
  if (!['dry-run', 'stage', 'verify'].includes(mode)) throw new Error('Invalid import mode');
  const limits = {};
  for (const [option, field] of positiveOptions) {
    if (values.has(option)) {
      const value = Number(values.get(option));
      if (!Number.isSafeInteger(value) || value < 1) throw new Error('Invalid import limit');
      limits[field] = value;
    }
  }
  return { values, mode, limits };
}

function outside(rootPath, path) {
  const portion = relative(rootPath, path);
  return portion === '..' || portion.startsWith(`..${sep}`) || isAbsolute(portion);
}

async function privateInput(path, label) {
  const resolved = await realpath(path);
  if (!outside(await realpath(root), resolved) || resolved.includes('.partial-')) {
    throw new Error(`${label} must be a completed private file outside the repository`);
  }
  const info = await stat(resolved);
  if (!info.isFile() || (info.mode & 0o077) !== 0) {
    throw new Error(`${label} must be a private regular file`);
  }
  return resolved;
}

function databaseConfig(urlText, caPath, confirmedDatabase) {
  const url = new URL(urlText);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !url.hostname
      || !url.username || !url.password || !url.pathname || url.pathname === '/'
      || url.hash || [...url.searchParams.keys()].some((name) => name !== 'sslmode')
      || url.searchParams.get('sslmode') !== 'verify-full') {
    throw new Error('Invalid PostgreSQL target configuration');
  }
  const database = decodeURIComponent(url.pathname.slice(1));
  const port = url.port ? Number(url.port) : 5432;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('Invalid PostgreSQL target port');
  }
  if (!confirmedDatabase || confirmedDatabase !== database) {
    throw new Error('Target database confirmation does not match');
  }
  return {
    host: url.hostname, port,
    user: decodeURIComponent(url.username), password: decodeURIComponent(url.password),
    database, ssl: { rejectUnauthorized: true,
      ...(caPath ? { ca: readFileSync(caPath, 'utf8') } : {}) },
    connectionTimeoutMillis: 5000, application_name: 'clrs_legacy_stage_import',
  };
}

async function main() {
  const { values, mode, limits } = argsMap(process.argv.slice(2));
  const archivePath = await privateInput(values.get('--archive'), 'Archive');
  const keyPath = await privateInput(values.get('--key-file'), 'Key');
  if (archivePath === keyPath) throw new Error('Archive and key must be different files');
  const key = await readFile(keyPath);
  if (key.length !== 32) throw new Error('Archive key must be 32 bytes');
  const expectedSource = {
    project: values.get('--project'), database: values.get('--database'),
    bucket: values.get('--bucket'),
  };
  const common = { archivePath, key, expectedSource, limits };
  if (mode === 'dry-run') {
    const result = await stageImport(common);
    process.stdout.write(`${JSON.stringify({ mode, ...result.counts })}\n`);
    return;
  }

  const mediaBucket = values.get('--target-media-bucket');
  if (!mediaBucket || !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(mediaBucket)
      || mediaBucket !== values.get('--confirm-private-bucket')) {
    throw new Error('A private target media bucket must be confirmed');
  }
  const endpoint = new URL(process.env.S3_ENDPOINT ?? '');
  const timewebBucketId = Number(values.get('--timeweb-bucket-id'));
  if (endpoint.toString() !== 'https://s3.twcstorage.ru/'
      || !process.env.S3_REGION
      || !process.env.AWS_ACCESS_KEY_ID || !process.env.AWS_SECRET_ACCESS_KEY
      || !Number.isSafeInteger(timewebBucketId) || timewebBucketId < 1
      || !process.env.TIMEWEB_API_TOKEN) {
    throw new Error('Invalid private S3 target configuration');
  }
  const config = databaseConfig(process.env.DATABASE_URL ?? '',
    process.env.DATABASE_CA_FILE, values.get('--confirm-target-db'));
  const database = new pg.Client(config);
  const s3 = new S3Client({ endpoint: endpoint.toString(), region: process.env.S3_REGION,
    forcePathStyle: true });
  try {
    await database.connect();
    const media = createPrivateS3MediaAdapter(s3, mediaBucket);
    const privacyCheck = (probe) => assertPrivateMediaBucket({
      client: s3, bucket: mediaBucket, bucketId: timewebBucketId,
      timewebToken: process.env.TIMEWEB_API_TOKEN,
      endpoint: endpoint.toString(), probe,
    });
    const result = mode === 'verify'
      ? await verifyStagedImport({ ...common, media,
        beforeRead: () => privacyCheck(false),
        db: createPostgresVerificationAdapter(database, config.database) })
      : await stageImport({ ...common, dryRun: false, media,
        beforeWrite: () => privacyCheck(true),
        beforeCommit: () => privacyCheck(false),
        db: createPostgresImportAdapter(database, config.database) });
    process.stdout.write(`${JSON.stringify({ mode, ...result.counts })}\n`);
  } finally {
    await database.end().catch(() => {});
    s3.destroy();
  }
}

main().catch(() => {
  // SDK/SQL errors can contain hostnames, IDs or private data; never print them.
  process.stderr.write('CLRSX2 import failed. Inspect private local diagnostics.\n');
  process.exitCode = 1;
});
