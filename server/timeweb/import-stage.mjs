import { scanImportArchive } from './import-core.mjs';

export class ImportCommitUncertainError extends Error {
  constructor(cause) {
    super('Import commit outcome is unknown; verify the existing target before retry', { cause });
    this.name = 'ImportCommitUncertainError';
    this.commitOutcomeUnknown = true;
    this.requiresVerification = true;
  }
}

function assertSource(source, expected) {
  if (!expected || source.project !== expected.project
      || source.database !== expected.database || source.bucket !== expected.bucket) {
    throw new Error('Archive source does not match the confirmed Firebase source');
  }
}

// The first pass authenticates and validates the entire archive without any
// external write. A failed second pass rolls back PostgreSQL; private S3 keys
// already written are content-verified and safe to reuse on a retry.
export async function stageImport({ archivePath, key, expectedSource, limits,
  dryRun = true, db, media, beforeWrite, beforeCommit }) {
  const checked = await scanImportArchive({ archivePath, key, limits });
  assertSource(checked.source, expectedSource);
  if (dryRun) return { ...checked, imported: false };
  if (!db || !media) throw new Error('Database and private media adapters are required');

  let commitStarted = false;
  try {
    if (!beforeWrite) throw new Error('Private media preflight is required');
    await beforeWrite();
    await db.begin(checked.source);
    const imported = await scanImportArchive({
      archivePath, key, limits,
      onAuth: (record) => db.stageAuth(record),
      onDocument: (record) => db.stageDocument(record),
      onObject: async (record) => {
        // A buffered SQL conflict must fail before this object is uploaded.
        if (db.flush) await db.flush();
        await media.ensure(record);
        await db.stageObject(record);
      },
    });
    assertSource(imported.source, expectedSource);
    if (JSON.stringify(imported.summary) !== JSON.stringify(checked.summary)
        || JSON.stringify(imported.counts) !== JSON.stringify(checked.counts)
        || imported.archiveSha256 !== checked.archiveSha256) {
      throw new Error('Archive changed between validation and import');
    }
    if (db.flush) await db.flush();
    if (!beforeCommit) throw new Error('Private media final check is required');
    await beforeCommit();
    commitStarted = true;
    await db.commit();
    commitStarted = false;
    return { ...imported, imported: true };
  } catch (error) {
    // A failed COMMIT acknowledgement does not prove rollback, even if a
    // subsequent ROLLBACK appears successful. Never auto-retry this outcome.
    try { await db.rollback(); } catch { /* preserve the initial error */ }
    if (commitStarted) throw new ImportCommitUncertainError(error);
    throw error;
  }
}

export async function verifyStagedImport({ archivePath, key, expectedSource, limits,
  db, media, beforeRead }) {
  if (!db || !media) throw new Error('Database and private media adapters are required');
  const checked = await scanImportArchive({ archivePath, key, limits });
  assertSource(checked.source, expectedSource);
  try {
    if (!beforeRead) throw new Error('Private media preflight is required');
    await beforeRead();
    await db.begin(checked.source);
    const verified = await scanImportArchive({
      archivePath, key, limits,
      onAuth: (record) => db.verifyAuth(record),
      onDocument: (record) => db.verifyDocument(record),
      onObject: async (record) => {
        if (db.flush) await db.flush();
        await db.verifyObject(record);
        await media.verify(record);
      },
    });
    if (JSON.stringify(verified.summary) !== JSON.stringify(checked.summary)
        || verified.archiveSha256 !== checked.archiveSha256) {
      throw new Error('Archive changed during verification');
    }
    if (db.flush) await db.flush();
    await db.verifyCounts(verified.counts, verified.source);
    await db.commit();
    return { ...verified, verified: true };
  } catch (error) {
    try { await db.rollback(); } catch { /* preserve the initial error */ }
    throw error;
  }
}
