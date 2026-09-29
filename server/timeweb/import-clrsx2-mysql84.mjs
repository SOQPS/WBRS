#!/usr/bin/env node
import { S3Client } from '@aws-sdk/client-s3';
import { loadImportInputs, parseImportArgs, privateMediaConfig } from './import-cli-common.mjs';
import { createPrivateS3MediaAdapter } from './import-adapters.mjs';
import { stageImport, verifyStagedImport } from './import-stage.mjs';
import { createMySql84ImportAdapter,
  createMySql84VerificationAdapter } from './import-mysql84-adapters.mjs';
import { mysql84Config } from './import-mysql84-cli-config.mjs';
import { assertPrivateMediaBucket } from './s3-privacy.mjs';

async function main() {
  const { values, mode, limits } = parseImportArgs(process.argv.slice(2));
  const common = await loadImportInputs(values, limits);
  if (mode === 'dry-run') {
    const result = await stageImport(common);
    process.stdout.write(`${JSON.stringify({ mode, ...result.counts })}\n`);
    return;
  }

  // Validate every target confirmation and private file before opening a socket.
  const { mediaBucket, endpoint, timewebBucketId, region, timewebToken } =
    privateMediaConfig(values);
  const config = await mysql84Config(values);
  const mysql = await import('mysql2/promise');
  const s3 = new S3Client({ endpoint, region, forcePathStyle: true });
  let database;
  try {
    database = await mysql.createConnection(config);
    const media = createPrivateS3MediaAdapter(s3, mediaBucket);
    const privacyCheck = (probe) => assertPrivateMediaBucket({
      client: s3, bucket: mediaBucket, bucketId: timewebBucketId,
      timewebToken, endpoint, probe,
    });
    const result = mode === 'verify'
      ? await verifyStagedImport({ ...common, media,
        beforeRead: () => privacyCheck(false),
        db: createMySql84VerificationAdapter(database, config.database) })
      : await stageImport({ ...common, dryRun: false, media,
        beforeWrite: () => privacyCheck(true),
        beforeCommit: () => privacyCheck(false),
        db: createMySql84ImportAdapter(database, config.database) });
    process.stdout.write(`${JSON.stringify({ mode, ...result.counts })}\n`);
  } finally {
    if (database) await database.end().catch(() => {});
    s3.destroy();
  }
}

main().catch(() => {
  // Driver/SQL errors may contain hostnames, IDs or private data.
  process.stderr.write('CLRSX2 MySQL import failed. Inspect private local diagnostics.\n');
  process.exitCode = 1;
});
