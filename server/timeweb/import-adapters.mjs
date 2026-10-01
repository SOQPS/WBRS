import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { payloadHash } from './import-core.mjs';
import { assertPrivateObjectAcl } from './s3-privacy.mjs';

function samePayload(left, right) {
  return payloadHash(left) === payloadHash(right) && isDeepStrictEqual(left, right);
}

async function retainedRow(client, sql, params, matches, conflictLabel) {
  const result = await client.query(sql, params);
  if (result.rows.length !== 1 || !matches(result.rows[0])) {
    throw new Error(`Existing ${conflictLabel} conflicts with archive`);
  }
}

export function createPostgresImportAdapter(client, expectedDatabase) {
  let begun = false;
  return {
    async begin(source) {
      if (begun) throw new Error('Import transaction already open');
      await client.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
      begun = true;
      const database = await client.query('SELECT current_database() AS name');
      if (database.rows[0]?.name !== expectedDatabase) {
        throw new Error('Target PostgreSQL database does not match confirmation');
      }
      const schema = await client.query('SELECT version FROM clrs.schema_migrations');
      if (schema.rows.length !== 1 || schema.rows[0].version !== 1) {
        throw new Error('Target PostgreSQL schema version mismatch');
      }
      await client.query("SELECT pg_advisory_xact_lock(hashtext('clrs:legacy_import'))");
      await client.query(`INSERT INTO clrs.legacy_source
        (singleton, source_project, source_database, source_bucket)
        VALUES (true, $1, $2, $3) ON CONFLICT (singleton) DO NOTHING`,
      [source.project, source.database, source.bucket]);
      await retainedRow(client, `SELECT source_project, source_database, source_bucket
        FROM clrs.legacy_source WHERE singleton = true FOR UPDATE`, [],
      (row) => row.source_project === source.project
        && row.source_database === source.database && row.source_bucket === source.bucket,
      'Firebase source');
    },

    async stageAuth({ uid, encodedPayload, sha256 }) {
      await client.query(`INSERT INTO clrs.legacy_auth_users
        (uid, encoded_payload, payload_sha256)
        VALUES ($1, $2::jsonb, decode($3, 'hex')) ON CONFLICT (uid) DO NOTHING`,
      [uid, JSON.stringify(encodedPayload), sha256]);
      await retainedRow(client, `SELECT encoded_payload,
        encode(payload_sha256, 'hex') AS sha256 FROM clrs.legacy_auth_users WHERE uid = $1`,
      [uid], (row) => row.sha256 === sha256 && samePayload(row.encoded_payload, encodedPayload),
      'Auth UID');
    },

    async stageDocument({ firebasePath, parentPath, collectionPath,
      documentId, encodedPayload, sha256 }) {
      await client.query(`INSERT INTO clrs.legacy_documents
        (firebase_path, parent_path, collection_path, document_id,
         encoded_payload, payload_sha256)
        VALUES ($1, $2, $3, $4, $5::jsonb, decode($6, 'hex'))
        ON CONFLICT (firebase_path) DO NOTHING`,
      [firebasePath, parentPath, collectionPath, documentId,
        JSON.stringify(encodedPayload), sha256]);
      await retainedRow(client, `SELECT parent_path, collection_path, document_id,
        encoded_payload, encode(payload_sha256, 'hex') AS sha256
        FROM clrs.legacy_documents WHERE firebase_path = $1`, [firebasePath],
      (row) => row.parent_path === parentPath && row.collection_path === collectionPath
        && row.document_id === documentId && row.sha256 === sha256
        && samePayload(row.encoded_payload, encodedPayload), 'Firestore path');
    },

    async stageObject({ source, name, metadata, size, sha256, targetKey }) {
      await client.query(`INSERT INTO clrs.legacy_storage_objects
        (source_bucket, source_path, source_metadata, source_size, source_sha256,
         target_key, target_sha256, copied_at)
        VALUES ($1, $2, $3::jsonb, $4, decode($5, 'hex'), $6,
                decode($5, 'hex'), now())
        ON CONFLICT (source_bucket, source_path) DO NOTHING`,
      [source.bucket, name, JSON.stringify(metadata), size, sha256, targetKey]);
      await retainedRow(client, `SELECT source_metadata, source_size,
        encode(source_sha256, 'hex') AS source_sha256, target_key,
        encode(target_sha256, 'hex') AS target_sha256, copied_at
        FROM clrs.legacy_storage_objects
        WHERE source_bucket = $1 AND source_path = $2`, [source.bucket, name],
      (row) => samePayload(row.source_metadata, metadata)
        && Number(row.source_size) === size && row.source_sha256 === sha256
        && row.target_key === targetKey && row.target_sha256 === sha256
        && row.copied_at !== null, 'Storage path');
    },

    async commit() {
      if (!begun) throw new Error('Import transaction is not open');
      await client.query('COMMIT');
      begun = false;
    },
    async rollback() {
      if (begun) {
        try { await client.query('ROLLBACK'); } finally { begun = false; }
      }
    },
  };
}

export function createPostgresVerificationAdapter(client, expectedDatabase) {
  let opened = false;
  return {
    async begin(source) {
      await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY');
      opened = true;
      const database = await client.query('SELECT current_database() AS name');
      if (database.rows[0]?.name !== expectedDatabase) {
        throw new Error('Target PostgreSQL database does not match confirmation');
      }
      const schema = await client.query('SELECT version FROM clrs.schema_migrations');
      if (schema.rows.length !== 1 || schema.rows[0].version !== 1) {
        throw new Error('Target PostgreSQL schema version mismatch');
      }
      await retainedRow(client, `SELECT source_project, source_database, source_bucket
        FROM clrs.legacy_source WHERE singleton = true`, [],
      (row) => row.source_project === source.project
        && row.source_database === source.database && row.source_bucket === source.bucket,
      'Firebase source');
    },
    async verifyAuth({ uid, encodedPayload, sha256 }) {
      await retainedRow(client, `SELECT encoded_payload,
        encode(payload_sha256, 'hex') AS sha256 FROM clrs.legacy_auth_users WHERE uid = $1`,
      [uid], (row) => row.sha256 === sha256 && samePayload(row.encoded_payload, encodedPayload),
      'Auth UID');
    },
    async verifyDocument({ firebasePath, parentPath, collectionPath,
      documentId, encodedPayload, sha256 }) {
      await retainedRow(client, `SELECT parent_path, collection_path, document_id,
        encoded_payload, encode(payload_sha256, 'hex') AS sha256
        FROM clrs.legacy_documents WHERE firebase_path = $1`, [firebasePath],
      (row) => row.parent_path === parentPath && row.collection_path === collectionPath
        && row.document_id === documentId && row.sha256 === sha256
        && samePayload(row.encoded_payload, encodedPayload), 'Firestore path');
    },
    async verifyObject({ source, name, metadata, size, sha256, targetKey }) {
      await retainedRow(client, `SELECT source_metadata, source_size,
        encode(source_sha256, 'hex') AS source_sha256, target_key,
        encode(target_sha256, 'hex') AS target_sha256, copied_at
        FROM clrs.legacy_storage_objects
        WHERE source_bucket = $1 AND source_path = $2`, [source.bucket, name],
      (row) => samePayload(row.source_metadata, metadata)
        && Number(row.source_size) === size && row.source_sha256 === sha256
        && row.target_key === targetKey && row.target_sha256 === sha256
        && row.copied_at !== null, 'Storage path');
    },
    async verifyCounts(counts, source) {
      const result = await client.query(`SELECT
        (SELECT count(*) FROM clrs.legacy_auth_users) AS auth_users,
        (SELECT count(*) FROM clrs.legacy_documents) AS firestore_documents,
        (SELECT count(*) FROM clrs.legacy_storage_objects
          WHERE source_bucket = $1) AS storage_objects,
        (SELECT coalesce(sum(source_size), 0) FROM clrs.legacy_storage_objects
          WHERE source_bucket = $1) AS storage_bytes`, [source.bucket]);
      const row = result.rows[0];
      if (!row || Number(row.auth_users) !== counts.authUsers
          || Number(row.firestore_documents) !== counts.firestoreDocuments
          || Number(row.storage_objects) !== counts.storageObjects
          || Number(row.storage_bytes) !== counts.storageBytes) {
        throw new Error('Staged target count mismatch');
      }
    },
    async commit() {
      if (!opened) throw new Error('Verification transaction is not open');
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

function missingObject(error) {
  return error?.name === 'NoSuchKey' || error?.name === 'NotFound'
    || error?.$metadata?.httpStatusCode === 404;
}

export const S3_IMPORT_TIMEOUTS = Object.freeze({ operationTimeoutMs: 35_000,
  uploadTimeoutMs: 120_000, streamTimeoutMs: 120_000, streamIdleTimeoutMs: 15_000 });

function timeouts(options) {
  const result = { ...S3_IMPORT_TIMEOUTS };
  for (const [name, cap] of Object.entries(result)) {
    const value = options[name] ?? cap;
    if (!Number.isSafeInteger(value) || value < 1 || value > cap) {
      throw new Error('Invalid private media timeout');
    }
    result[name] = value;
  }
  if (result.operationTimeoutMs > result.streamTimeoutMs
      || result.streamIdleTimeoutMs > result.streamTimeoutMs) {
    throw new Error('Invalid private media timeout ordering');
  }
  return result;
}

function timeoutError() {
  const error = new Error('Private media deadline exceeded');
  error.name = 'TimeoutError'; error.code = 'CLRS_MEDIA_TIMEOUT';
  return error;
}

function destroyBody(body) {
  // Cleanup must not replace the original checksum/network/deadline error.
  try { body?.destroy?.(); } catch { /* no private diagnostics */ }
}

async function boundedSend(client, command, budget, sdkBudget, options = {}) {
  const controller = new AbortController();
  let timer; let abort; let expired = false;
  const deadline = new Promise((_, reject) => {
    const fail = (error) => { expired = true; reject(error); controller.abort(error); };
    timer = setTimeout(() => fail(timeoutError()), budget);
    if (options.abortSignal) {
      abort = () => {
        const error = new Error('Private media operation aborted'); error.name = 'AbortError';
        fail(error);
      };
      if (options.abortSignal.aborted) abort();
      else options.abortSignal.addEventListener('abort', abort, { once: true });
    }
  });
  try {
    return await Promise.race([deadline, Promise.resolve().then(async () => {
      if (client.config?.maxAttempts !== undefined) {
        const attempts = typeof client.config.maxAttempts === 'function'
          ? await client.config.maxAttempts() : client.config.maxAttempts;
        if (attempts !== 1) throw new Error('Private media automatic retries must be disabled');
      }
      if (controller.signal.aborted) throw controller.signal.reason;
      return Promise.resolve(client.send(command, { ...options, abortSignal: controller.signal,
        requestTimeout: sdkBudget })).then((result) => {
        // A custom transport or response race may complete after abort. Never
        // leave that discarded HTTP body/socket open.
        if (expired) destroyBody(result?.Body);
        return result;
      });
    })]);
  } catch (error) {
    controller.abort();
    throw error;
  } finally {
    clearTimeout(timer);
    if (abort) options.abortSignal.removeEventListener('abort', abort);
  }
}

// Use this wrapper for bucket ACL/policy/probe checks too. SDK maxAttempts must
// separately be 1: a lost PUT response is reconciled by a later explicit verify,
// never by an automatic importer retry.
export function createBoundedS3Transport(client, options = {}) {
  const limits = timeouts(options);
  return { send(command, sendOptions) {
    const put = command instanceof PutObjectCommand;
    return boundedSend(client, command,
      put ? limits.uploadTimeoutMs : limits.operationTimeoutMs,
      put || command instanceof GetObjectCommand
        ? limits.streamTimeoutMs : limits.operationTimeoutMs, sendOptions);
  } };
}

async function verifyBody(body, record, absoluteTimeoutMs, idleTimeoutMs) {
  const hash = createHash('sha256');
  let size = 0; let absoluteTimer; let idleTimer; let rejectDeadline; let stopped = false;
  const deadline = new Promise((_, reject) => { rejectDeadline = reject; });
  const expire = () => { if (!stopped) { rejectDeadline(timeoutError()); destroyBody(body); } };
  const resetIdle = () => {
    clearTimeout(idleTimer);
    if (!stopped) idleTimer = setTimeout(expire, idleTimeoutMs);
  };
  absoluteTimer = setTimeout(expire, absoluteTimeoutMs); resetIdle();
  const reading = (async () => {
    for await (const chunk of body) {
      if (stopped) break;
      size += chunk.length;
      if (size > record.size) throw new Error('Private media object size mismatch');
      if (chunk.length) resetIdle();
      hash.update(chunk);
    }
    if (size !== record.size || hash.digest('hex') !== record.sha256) {
      throw new Error('Private media object checksum mismatch');
    }
  })();
  try { await Promise.race([reading, deadline]); }
  catch (error) { destroyBody(body); throw error; }
  finally { stopped = true; clearTimeout(absoluteTimer); clearTimeout(idleTimer); }
}

async function verifyObject(client, bucket, record, limits) {
  const started = performance.now();
  await assertPrivateObjectAcl(client, bucket, record.targetKey);
  const result = await client.send(new GetObjectCommand({ Bucket: bucket, Key: record.targetKey }));
  try {
    if (!result.Body || result.ContentType !== (record.metadata.contentType ?? 'application/octet-stream')) {
      throw new Error('Private media object metadata mismatch');
    }
    const remaining = Math.ceil(limits.streamTimeoutMs - (performance.now() - started));
    if (remaining < 1) throw timeoutError();
    await verifyBody(result.Body, record, remaining, limits.streamIdleTimeoutMs);
  } catch (error) { destroyBody(result.Body); throw error; }
}

export function createPrivateS3MediaAdapter(client, bucket, options = {}) {
  const limits = timeouts(options);
  const transport = createBoundedS3Transport(client, limits);
  const progress = { verifiedObjects: 0, verifiedBytes: 0, putAttempts: 0 };
  async function completed(record) {
    progress.verifiedObjects++; progress.verifiedBytes += record.size;
    if (options.onProgress) await options.onProgress({ ...progress });
  }
  return {
    async verify(record) { await verifyObject(transport, bucket, record, limits); await completed(record); },
    async ensure(record) {
      try {
        await verifyObject(transport, bucket, record, limits);
        await completed(record);
        return;
      } catch (error) {
        if (!missingObject(error)) throw error;
      }
      try {
        progress.putAttempts++;
        await transport.send(new PutObjectCommand({
          Bucket: bucket, Key: record.targetKey, Body: record.bytes,
          ContentType: record.metadata.contentType ?? 'application/octet-stream',
          Metadata: { 'clrs-sha256': record.sha256 }, IfNoneMatch: '*',
        }));
      } catch (error) {
        // A concurrent importer may have written the same immutable key.
        if (error?.$metadata?.httpStatusCode !== 412 && error?.name !== 'PreconditionFailed') {
          throw error;
        }
      }
      await verifyObject(transport, bucket, record, limits);
      await completed(record);
    },
  };
}
