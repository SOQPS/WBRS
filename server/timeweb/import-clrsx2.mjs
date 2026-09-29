#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import pg from 'pg';
import { S3Client } from '@aws-sdk/client-s3';
import { loadImportInputs, parseImportArgs, privateMediaConfig } from './import-cli-common.mjs';
import { createPostgresImportAdapter, createPostgresVerificationAdapter,
  createPrivateS3MediaAdapter } from './import-adapters.mjs';
import { stageImport, verifyStagedImport } from './import-stage.mjs';
import { assertPrivateMediaBucket } from './s3-privacy.mjs';

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
  const { values, mode, limits } = parseImportArgs(process.argv.slice(2));
  const common = await loadImportInputs(values, limits);
  if (mode === 'dry-run') {
    const result = await stageImport(common);
    process.stdout.write(`${JSON.stringify({ mode, ...result.counts })}\n`);
    return;
  }

  const { mediaBucket, endpoint, timewebBucketId, region, timewebToken } =
    privateMediaConfig(values);
  const config = databaseConfig(process.env.DATABASE_URL ?? '',
    process.env.DATABASE_CA_FILE, values.get('--confirm-target-db'));
  const database = new pg.Client(config);
  const s3 = new S3Client({ endpoint, region,
    forcePathStyle: true });
  try {
    await database.connect();
    const media = createPrivateS3MediaAdapter(s3, mediaBucket);
    const privacyCheck = (probe) => assertPrivateMediaBucket({
      client: s3, bucket: mediaBucket, bucketId: timewebBucketId,
      timewebToken, endpoint, probe,
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
