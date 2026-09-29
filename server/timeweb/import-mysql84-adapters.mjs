import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { payloadHash } from './import-core.mjs';

const DATABASE = 'clrs_staging';

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
    @@character_set_connection AS character_set_connection`);
  const row = target[0];
  if (target.length !== 1 || row.target_database !== expectedDatabase
      || !/^8\.4\./.test(row.mysql_version ?? '')
      || row.character_set_connection !== 'utf8mb4'
      || !/(^|,)(STRICT_TRANS_TABLES|STRICT_ALL_TABLES)(,|$)/.test(row.sql_mode ?? '')) {
    throw new Error('Target MySQL 8.4 database or session configuration mismatch');
  }
  const migrations = await rows(client,
    'SELECT version FROM clrs_staging.schema_migrations ORDER BY version');
  if (migrations.length !== 1 || Number(migrations[0].version) !== 1) {
    throw new Error('Target MySQL schema version mismatch');
  }
}

async function checkRetainedSource(client, source, forUpdate) {
  await retainedRow(client, `SELECT source_project, source_database, source_bucket
    FROM clrs_staging.legacy_source WHERE singleton = 1${forUpdate ? ' FOR UPDATE' : ''}`,
  [], (row) => row.source_project === source.project
    && row.source_database === source.database && row.source_bucket === source.bucket,
  'Firebase source');
}

async function checkAuth(client, { uid, encodedPayload, sha256: payloadSha256 }, forUpdate) {
  await retainedRow(client, `SELECT uid, encoded_payload, HEX(payload_sha256) AS payload_hash
    FROM clrs_staging.legacy_auth_users WHERE uid_sha256 = UNHEX(?)${forUpdate ? ' FOR UPDATE' : ''}`,
  [sha256(uid)], (row) => row.uid === uid
    && sameHash(row.payload_hash, payloadSha256)
    && samePayload(row.encoded_payload, encodedPayload), 'Auth UID');
}

async function checkDocument(client, { firebasePath, parentPath, collectionPath,
  documentId, encodedPayload, sha256: payloadSha256 }, forUpdate) {
  await retainedRow(client, `SELECT firebase_path, parent_path, collection_path,
    document_id, encoded_payload, HEX(payload_sha256) AS payload_hash
    FROM clrs_staging.legacy_documents
    WHERE firebase_path_sha256 = UNHEX(?)${forUpdate ? ' FOR UPDATE' : ''}`,
  [sha256(firebasePath)], (row) => row.firebase_path === firebasePath
    && row.parent_path === parentPath && row.collection_path === collectionPath
    && row.document_id === documentId && sameHash(row.payload_hash, payloadSha256)
    && samePayload(row.encoded_payload, encodedPayload), 'Firestore path');
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
  return {
    requireOpen() {
      if (!opened) throw new Error('Import transaction is not open');
    },
    async begin(source) {
      if (opened) throw new Error('Import transaction already open');
      assertSource(source);
      await client.query("SET SESSION time_zone = '+00:00'");
      await client.query(`SET TRANSACTION ISOLATION LEVEL ${readOnly ? 'REPEATABLE READ' : 'SERIALIZABLE'}`);
      await client.query(`START TRANSACTION${readOnly ? ' READ ONLY' : ''}`);
      opened = true;
      await checkTarget(client, expectedDatabase);
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
    },
    async rollback() {
      if (opened) {
        try { await client.query('ROLLBACK'); } finally { opened = false; }
      }
    },
  };
}

// client is one pinned mysql2/promise Connection (not a Pool); stageImport
// owns the transaction and performs its archive and private-S3 preflights.
export function createMySql84ImportAdapter(client, expectedDatabase) {
  const { requireOpen, ...actions } = transaction(client, expectedDatabase, false);
  return {
    ...actions,
    async stageAuth(record) {
      requireOpen();
      await client.execute(`INSERT INTO clrs_staging.legacy_auth_users
        (uid, encoded_payload, payload_sha256) VALUES (?, ?, UNHEX(?))
        ON DUPLICATE KEY UPDATE archive_id = archive_id`,
      [record.uid, JSON.stringify(record.encodedPayload), record.sha256]);
      await checkAuth(client, record, true);
    },
    async stageDocument(record) {
      requireOpen();
      await client.execute(`INSERT INTO clrs_staging.legacy_documents
        (firebase_path, parent_path, collection_path, document_id,
         encoded_payload, payload_sha256)
        VALUES (?, ?, ?, ?, ?, UNHEX(?))
        ON DUPLICATE KEY UPDATE archive_id = archive_id`,
      [record.firebasePath, record.parentPath, record.collectionPath,
        record.documentId, JSON.stringify(record.encodedPayload), record.sha256]);
      await checkDocument(client, record, true);
    },
    async stageObject(record) {
      requireOpen();
      await client.execute(`INSERT INTO clrs_staging.legacy_storage_objects
        (source_bucket, source_path, source_metadata, source_size,
         source_sha256, target_key, target_sha256, copied_at)
        VALUES (?, ?, ?, ?, UNHEX(?), ?, UNHEX(?), UTC_TIMESTAMP(6))
        ON DUPLICATE KEY UPDATE archive_id = archive_id`,
      [record.source.bucket, record.name, JSON.stringify(record.metadata),
        record.size, record.sha256, record.targetKey, record.sha256]);
      await checkObject(client, record, true);
    },
  };
}

export function createMySql84VerificationAdapter(client, expectedDatabase) {
  const { requireOpen, ...actions } = transaction(client, expectedDatabase, true);
  return {
    ...actions,
    async verifyAuth(record) { requireOpen(); await checkAuth(client, record, false); },
    async verifyDocument(record) { requireOpen(); await checkDocument(client, record, false); },
    async verifyObject(record) { requireOpen(); await checkObject(client, record, false); },
    async verifyCounts(counts) {
      requireOpen();
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
    },
  };
}
