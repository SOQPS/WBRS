import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { payloadHash } from './import-core.mjs';

const DATABASE = 'clrs_staging';
const BATCH_ROWS = 100;
// mysql2 execute uses binary parameters, but reserve twice the UTF-8/JSON
// bytes for both its framing and MySQL's returned JSON representation.
const BATCH_OVERHEAD = 1024;

function sha256(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function jsonValue(value) {
  if (typeof value === 'string' || Buffer.isBuffer(value)) {
    return JSON.parse(value.toString());
  }
  return value;
}

function samePayload(stored, expected) {
  const decoded = jsonValue(stored);
  return payloadHash(decoded) === payloadHash(expected)
    && isDeepStrictEqual(decoded, expected);
}

function sameHash(stored, expected) {
  return typeof stored === 'string' && stored.toLowerCase() === expected;
}

function assertSource(source) {
  for (const name of ['project', 'database', 'bucket']) {
    if (typeof source?.[name] !== 'string' || !source[name]
        || [...source[name]].length > 191) {
      throw new Error('Firebase source identifier does not fit MySQL staging schema');
    }
  }
}

function assertDatabase(expectedDatabase) {
  if (expectedDatabase !== DATABASE) {
    throw new Error('MySQL importer requires explicit clrs_staging confirmation');
  }
}

async function rows(client, sql, params = []) {
  const [result] = await client.execute(sql, params);
  if (!Array.isArray(result)) throw new Error('Expected mysql2/promise SELECT rows');
  return result;
}

async function retainedRow(client, sql, params, matches, label) {
  const result = await rows(client, sql, params);
  if (result.length !== 1 || !matches(result[0])) {
    throw new Error(`Existing ${label} conflicts with archive`);
  }
}

async function checkTarget(client, expectedDatabase) {
  const target = await rows(client, `SELECT DATABASE() AS target_database,
    VERSION() AS mysql_version, @@SESSION.sql_mode AS sql_mode,
    @@character_set_connection AS character_set_connection,
    @@max_allowed_packet AS max_allowed_packet`);
  const row = target[0];
  if (target.length !== 1 || row.target_database !== expectedDatabase
      || !/^8\.4\./.test(row.mysql_version ?? '')
      || row.character_set_connection !== 'utf8mb4'
      || !Number.isSafeInteger(Number(row.max_allowed_packet))
      || Number(row.max_allowed_packet) < 4096
      || !/(^|,)(STRICT_TRANS_TABLES|STRICT_ALL_TABLES)(,|$)/.test(row.sql_mode ?? '')) {
    throw new Error('Target MySQL 8.4 database or session configuration mismatch');
  }
  const migrations = await rows(client,
    'SELECT version FROM clrs_staging.schema_migrations ORDER BY version');
  if (migrations.length !== 1 || Number(migrations[0].version) !== 1) {
    throw new Error('Target MySQL schema version mismatch');
  }
  return Math.floor(Number(row.max_allowed_packet) / 2);
}

async function checkRetainedSource(client, source, forUpdate) {
  await retainedRow(client, `SELECT source_project, source_database, source_bucket
    FROM clrs_staging.legacy_source WHERE singleton = 1${forUpdate ? ' FOR UPDATE' : ''}`,
  [], (row) => row.source_project === source.project
    && row.source_database === source.database && row.source_bucket === source.bucket,
  'Firebase source');
}

async function checkObject(client, { source, name, metadata, size,
  sha256: sourceSha256, targetKey }, forUpdate) {
  await retainedRow(client, `SELECT source_bucket, source_path, source_metadata, source_size,
    HEX(source_sha256) AS source_hash, target_key,
    HEX(target_sha256) AS target_hash, copied_at
    FROM clrs_staging.legacy_storage_objects
    WHERE source_bucket = ? AND source_path_sha256 = UNHEX(?)${forUpdate ? ' FOR UPDATE' : ''}`,
  [source.bucket, sha256(name)], (row) => row.source_bucket === source.bucket
    && row.source_path === name && samePayload(row.source_metadata, metadata)
    && BigInt(row.source_size) === BigInt(size)
    && sameHash(row.source_hash, sourceSha256)
    && row.target_key === targetKey && sameHash(row.target_hash, sourceSha256)
    && row.copied_at !== null, 'Storage path');
}

function transaction(client, expectedDatabase, readOnly) {
  assertDatabase(expectedDatabase);
  let opened = false;
  let packetBudget = 0;
  return {
    requireOpen() {
      if (!opened) throw new Error('Import transaction is not open');
    },
    packetBudget() { return packetBudget; },
    async begin(source) {
      if (opened) throw new Error('Import transaction already open');
      assertSource(source);
      await client.query("SET SESSION time_zone = '+00:00'");
      // Timeweb's managed default is not strict; set only this pinned
      // migration connection before opening its transaction.
      await client.query("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'");
      await client.query(`SET TRANSACTION ISOLATION LEVEL ${readOnly ? 'REPEATABLE READ' : 'SERIALIZABLE'}`);
      await client.query(`START TRANSACTION${readOnly ? ' READ ONLY' : ''}`);
      opened = true;
      packetBudget = await checkTarget(client, expectedDatabase);
      if (!readOnly) {
        await client.execute(`INSERT INTO clrs_staging.legacy_source
          (singleton, source_project, source_database, source_bucket)
          VALUES (1, ?, ?, ?) ON DUPLICATE KEY UPDATE singleton = singleton`,
        [source.project, source.database, source.bucket]);
      }
      await checkRetainedSource(client, source, !readOnly);
    },
    async commit() {
      if (!opened) throw new Error('Import transaction is not open');
      await client.query('COMMIT');
      opened = false;
      packetBudget = 0;
    },
    async rollback() {
      if (opened) {
        try { await client.query('ROLLBACK'); } finally { opened = false; packetBudget = 0; }
      }
    },
  };
}

const TYPES = Object.freeze({
  auth: {
    label: 'Auth UID', table: 'legacy_auth_users', key: 'uid_sha256',
    columns: 'uid, encoded_payload, payload_sha256', values: '(?, ?, UNHEX(?))',
    select: 'uid, encoded_payload, HEX(payload_sha256) AS payload_hash',
    identity: (record) => record.uid,
    params: (record, encoded) => [record.uid, encoded, record.sha256],
    matches: (row, record) => row.uid === record.uid
      && sameHash(row.payload_hash, record.sha256)
      && samePayload(row.encoded_payload, record.encodedPayload),
  },
  documents: {
    label: 'Firestore path', table: 'legacy_documents', key: 'firebase_path_sha256',
    columns: 'firebase_path, parent_path, collection_path, document_id, encoded_payload, payload_sha256',
    values: '(?, ?, ?, ?, ?, UNHEX(?))',
    select: 'firebase_path, parent_path, collection_path, document_id, encoded_payload, HEX(payload_sha256) AS payload_hash',
    identity: (record) => record.firebasePath,
    params: (record, encoded) => [record.firebasePath, record.parentPath,
      record.collectionPath, record.documentId, encoded, record.sha256],
    matches: (row, record) => row.firebase_path === record.firebasePath
      && row.parent_path === record.parentPath && row.collection_path === record.collectionPath
      && row.document_id === record.documentId && sameHash(row.payload_hash, record.sha256)
      && samePayload(row.encoded_payload, record.encodedPayload),
  },
});

function prepared(kind, record) {
  const type = TYPES[kind];
  if (typeof type.identity(record) !== 'string' || !type.identity(record)
      || !/^[a-f0-9]{64}$/.test(record.sha256 ?? '')) {
    throw new Error(`Invalid ${type.label} staging record`);
  }
  // Take our own JSON snapshot: the caller cannot mutate a retained record
  // between enqueue and readback, nor silently alter a delayed batch.
  const encoded = JSON.stringify(record.encodedPayload);
  if (typeof encoded !== 'string' || payloadHash(record.encodedPayload) !== record.sha256) {
    throw new Error(`Invalid ${type.label} payload hash`);
  }
  const snapshot = { ...record, encodedPayload: JSON.parse(encoded) };
  const params = type.params(snapshot, encoded);
  if (params.some((value) => value !== null && typeof value !== 'string')) {
    throw new Error(`Invalid ${type.label} staging parameters`);
  }
  const size = params.reduce((total, value) => total + 32
    + (value === null ? 0 : 2 * Buffer.byteLength(value, 'utf8')), 128);
  return { record: snapshot, params, hash: sha256(type.identity(snapshot)), size };
}

async function checkedBatch(client, kind, batch, readOnly) {
  const type = TYPES[kind];
  if (!readOnly) {
    await client.execute(`INSERT INTO clrs_staging.${type.table}
      (${type.columns}) VALUES ${batch.map(() => type.values).join(', ')}
      ON DUPLICATE KEY UPDATE archive_id = archive_id`, batch.flatMap((item) => item.params));
  }
  const result = await rows(client, `SELECT HEX(${type.key}) AS archive_key, ${type.select}
    FROM clrs_staging.${type.table} WHERE ${type.key} IN (${batch.map(() => 'UNHEX(?)').join(', ')})${readOnly ? '' : ' FOR UPDATE'}`,
  batch.map((item) => item.hash));
  const expected = new Map(batch.map((item) => [item.hash, item.record]));
  if (result.length !== batch.length) throw new Error(`Existing ${type.label} conflicts with archive`);
  for (const row of result) {
    const key = typeof row.archive_key === 'string' ? row.archive_key.toLowerCase() : '';
    const record = expected.get(key);
    if (!record || !type.matches(row, record)) {
      throw new Error(`Existing ${type.label} conflicts with archive`);
    }
    expected.delete(key);
  }
  if (expected.size) throw new Error(`Existing ${type.label} conflicts with archive`);
}

// One pinned mysql2/promise Connection, used serially by the archive scanner.
// Buffered rows are always checked in the same transaction before S3/COMMIT.
function bufferedAdapter(client, expectedDatabase, readOnly) {
  const tx = transaction(client, expectedDatabase, readOnly);
  let batch = [];
  let kind;
  let batchBytes = BATCH_OVERHEAD;
  let failed = false;
  let busy = false;
  function requireOpen() {
    tx.requireOpen();
    if (failed) throw new Error('Import transaction failed; rollback is required');
  }
  function clear() { batch = []; kind = undefined; batchBytes = BATCH_OVERHEAD; }
  async function flush() {
    requireOpen();
    if (!batch.length) return;
    await checkedBatch(client, kind, batch, readOnly);
    clear();
  }
  async function guarded(operation) {
    if (busy) throw new Error('Concurrent import adapter call is not permitted');
    busy = true;
    try { return await operation(); } catch (error) { failed = true; throw error; }
    finally { busy = false; }
  }
  async function enqueue(nextKind, record) {
    requireOpen();
    const item = prepared(nextKind, record);
    if (BATCH_OVERHEAD + item.size > tx.packetBudget()) {
      throw new Error('Archive row exceeds the bounded MySQL packet budget');
    }
    if (batch.length && (kind !== nextKind || batch.length >= BATCH_ROWS
        || batchBytes + item.size > tx.packetBudget())) await flush();
    if (batch.some((current) => current.hash === item.hash)) {
      throw new Error(`Duplicate ${TYPES[nextKind].label} in batch`);
    }
    kind = nextKind;
    batch.push(item);
    batchBytes += item.size;
    if (batch.length === BATCH_ROWS) await flush();
  }
  const common = {
    async begin(source) {
      return guarded(async () => {
        clear(); failed = false;
        await tx.begin(source);
      });
    },
    async flush() { return guarded(flush); },
    async commit() { return guarded(async () => { await flush(); await tx.commit(); }); },
    async rollback() {
      // No buffered SQL is submitted after a failure or uncertain COMMIT.
      try { await tx.rollback(); } finally { clear(); failed = false; }
    },
  };
  if (!readOnly) return {
    ...common,
    async stageAuth(record) { return guarded(() => enqueue('auth', record)); },
    async stageDocument(record) { return guarded(() => enqueue('documents', record)); },
    async stageObject(record) {
      return guarded(async () => {
        await flush();
        await client.execute(`INSERT INTO clrs_staging.legacy_storage_objects
          (source_bucket, source_path, source_metadata, source_size,
           source_sha256, target_key, target_sha256, copied_at)
          VALUES (?, ?, ?, ?, UNHEX(?), ?, UNHEX(?), UTC_TIMESTAMP(6))
          ON DUPLICATE KEY UPDATE archive_id = archive_id`,
        [record.source.bucket, record.name, JSON.stringify(record.metadata),
          record.size, record.sha256, record.targetKey, record.sha256]);
        await checkObject(client, record, true);
      });
    },
  };
  return {
    ...common,
    async verifyAuth(record) { return guarded(() => enqueue('auth', record)); },
    async verifyDocument(record) { return guarded(() => enqueue('documents', record)); },
    async verifyObject(record) {
      return guarded(async () => { await flush(); await checkObject(client, record, false); });
    },
    async verifyCounts(counts) {
      return guarded(async () => {
        await flush();
        const result = await rows(client, `SELECT
        (SELECT COUNT(*) FROM clrs_staging.legacy_auth_users) AS auth_users,
        (SELECT COUNT(*) FROM clrs_staging.legacy_documents) AS firestore_documents,
        (SELECT COUNT(*) FROM clrs_staging.legacy_storage_objects) AS storage_objects,
        (SELECT COALESCE(SUM(source_size), 0)
          FROM clrs_staging.legacy_storage_objects) AS storage_bytes`);
        const row = result[0];
        if (result.length !== 1 || BigInt(row.auth_users) !== BigInt(counts.authUsers)
            || BigInt(row.firestore_documents) !== BigInt(counts.firestoreDocuments)
            || BigInt(row.storage_objects) !== BigInt(counts.storageObjects)
            || BigInt(row.storage_bytes) !== BigInt(counts.storageBytes)) {
          throw new Error('Staged target count mismatch');
        }
      });
    },
  };
}

export function createMySql84ImportAdapter(client, expectedDatabase) {
  return bufferedAdapter(client, expectedDatabase, false);
}

export function createMySql84VerificationAdapter(client, expectedDatabase) {
  return bufferedAdapter(client, expectedDatabase, true);
}
