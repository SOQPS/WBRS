import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { payloadHash, scanImportArchive } from '../import-core.mjs';
import { createMySql84ImportAdapter, createMySql84VerificationAdapter,
} from '../import-mysql84-adapters.mjs';
import { stageImport, verifyStagedImport } from '../import-stage.mjs';

const source = {
  kind: 'source', format: 2, project: 'clrs-synthetic', database: '(default)',
  bucket: 'clrs-synthetic.appspot.com', scope: 'all', storagePrefix: '',
  completeSource: true, passwordHashesIncluded: false, snapshotConsistent: false,
};
const expectedSource = {
  project: source.project, database: source.database, bucket: source.bucket,
};
const sha256 = (value) => createHash('sha256').update(value).digest('hex');
const bytes = Buffer.from('synthetic media bytes');
const longId = `photo-${'a'.repeat(230)}`;
const documentPath = `users/u1/images/${longId}`;
const storagePath = `avatars/${'b'.repeat(500)}.jpg`;
const summary = {
  authUsers: 1, authListPages: 1, firestoreDocuments: 1,
  firestoreMissingParents: 1, firestoreReferences: 2,
  firestoreCollections: 2, firestoreListPages: 2,
  storageObjects: 1, storageBytes: bytes.length, storageListPages: 1,
};

async function archive(t) {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-mysql84-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const archivePath = join(directory, 'source.clrsenc');
  const key = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(archivePath, key);
  await writer.writeJson(source);
  await writer.writeJson({ kind: 'auth-user', user: {
    uid: 'u1', email: 'synthetic@example.invalid', disabled: false,
  } });
  await writer.writeJson({ kind: 'firestore-document', path: documentPath,
    fields: { count: { integerValue: '9007199254740993' } },
    createTime: '2026-09-24T01:00:00Z', updateTime: '2026-09-25T01:00:00Z',
  });
  await writer.writeJson({ kind: 'storage-object', name: storagePath,
    metadata: { size: String(bytes.length), generation: '23',
      contentType: 'image/jpeg', metadata: { token: 'synthetic-only' } },
  });
  await writer.writeBytes(bytes);
  await writer.writeJson({ kind: 'storage-sha256', name: storagePath,
    sha256: sha256(bytes) });
  await writer.finish(summary);
  return { archivePath, key, expectedSource };
}

function emptyTables() {
  return { source: null, auth: new Map(), documents: new Map(), objects: new Map() };
}

// Simulates mysql2/promise's [rows, fields] shape and the schema's generated
// SHA-256 unique keys. It is intentionally not a substitute for a MySQL run.
function fakeMySql({ database = 'clrs_staging', version = '8.4.6',
  sqlMode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION',
  charset = 'utf8mb4', schemaVersion = 1, ignoreStrictMode = false,
  maxPacket = 64 * 1024 * 1024, fault, readTransform } = {}) {
  let committed = emptyTables();
  let working = null;
  let readOnly = false;
  const calls = [];
  const client = {
    get data() { return committed; },
    calls,
    async query(sql) {
      calls.push({ sql });
      if (fault) await fault({ sql, working, readOnly });
      if (sql === "SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'"
          && !ignoreStrictMode) sqlMode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';
      if (sql.startsWith('SET SESSION') || sql.startsWith('SET TRANSACTION')) return [[], []];
      if (sql.startsWith('START TRANSACTION')) {
        assert.equal(working, null);
        working = structuredClone(committed);
        readOnly = sql.includes('READ ONLY');
        return [[], []];
      }
      if (sql === 'COMMIT') {
        assert.ok(working);
        if (!readOnly) committed = working;
        working = null;
        return [[], []];
      }
      if (sql === 'ROLLBACK') {
        working = null;
        return [[], []];
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
    async execute(sql, params = []) {
      calls.push({ sql, params });
      assert.ok(working, 'SELECT and INSERT must stay in one transaction');
      if (fault) await fault({ sql, params, working, readOnly });
      if (sql.includes('SELECT DATABASE()')) {
        return [[{ target_database: database, mysql_version: version,
          sql_mode: sqlMode, character_set_connection: charset,
          max_allowed_packet: maxPacket }], []];
      }
      if (sql.includes('schema_migrations')) {
        return [[{ version: schemaVersion }], []];
      }
      if (sql.includes('INSERT INTO clrs_staging.legacy_source')) {
        assert.equal(readOnly, false);
        if (!working.source) {
          working.source = { source_project: params[0], source_database: params[1],
            source_bucket: params[2] };
        }
        return [{ affectedRows: 1 }, []];
      }
      if (sql.includes('FROM clrs_staging.legacy_source')) {
        return [working.source ? [working.source] : [], []];
      }
      if (sql.includes('INSERT INTO clrs_staging.legacy_auth_users')) {
        assert.equal(readOnly, false);
        for (let i = 0; i < params.length; i += 3) {
          const [uid, encodedPayload, payloadHash] = params.slice(i, i + 3);
          const key = sha256(uid);
          if (!working.auth.has(key)) working.auth.set(key, {
            uid, encoded_payload: encodedPayload, payload_hash: payloadHash.toUpperCase(),
          });
        }
        return [{ affectedRows: 1 }, []];
      }
      if (sql.includes('FROM clrs_staging.legacy_auth_users WHERE')) {
        const result = params.flatMap((key) => {
          const row = working.auth.get(key);
          return row ? [{ ...row, archive_key: key.toUpperCase() }] : [];
        }).reverse();
        return [readTransform ? readTransform(result, sql) : result, []];
      }
      if (sql.includes('INSERT INTO clrs_staging.legacy_documents')) {
        assert.equal(readOnly, false);
        for (let i = 0; i < params.length; i += 6) {
          const [firebasePath, parentPath, collectionPath, documentId,
            encodedPayload, payloadHash] = params.slice(i, i + 6);
          const key = sha256(firebasePath);
          if (!working.documents.has(key)) working.documents.set(key, {
            firebase_path: firebasePath, parent_path: parentPath,
            collection_path: collectionPath, document_id: documentId,
            encoded_payload: encodedPayload, payload_hash: payloadHash.toUpperCase(),
          });
        }
        return [{ affectedRows: 1 }, []];
      }
      if (/FROM clrs_staging\.legacy_documents\s+WHERE/.test(sql)) {
        const result = params.flatMap((key) => {
          const row = working.documents.get(key);
          return row ? [{ ...row, archive_key: key.toUpperCase() }] : [];
        }).reverse();
        return [readTransform ? readTransform(result, sql) : result, []];
      }
      if (sql.includes('INSERT INTO clrs_staging.legacy_storage_objects')) {
        assert.equal(readOnly, false);
        const [sourceBucket, sourcePath, sourceMetadata, sourceSize,
          sourceHash, targetKey, targetHash] = params;
        const key = `${sourceBucket}\0${sha256(sourcePath)}`;
        if (!working.objects.has(key)) working.objects.set(key, {
          source_bucket: sourceBucket, source_path: sourcePath,
          source_metadata: sourceMetadata, source_size: String(sourceSize),
          source_hash: sourceHash.toUpperCase(), target_key: targetKey,
          target_hash: targetHash.toUpperCase(), copied_at: '2026-09-30 00:00:00',
        });
        return [{ affectedRows: 1 }, []];
      }
      if (/FROM clrs_staging\.legacy_storage_objects\s+WHERE/.test(sql)) {
        const row = working.objects.get(`${params[0]}\0${params[1]}`);
        return [row ? [row] : [], []];
      }
      if (sql.includes('SELECT\n        (SELECT COUNT(*)')) {
        return [[{
          auth_users: String(working.auth.size),
          firestore_documents: String(working.documents.size),
          storage_objects: String(working.objects.size),
          storage_bytes: String([...working.objects.values()]
            .reduce((total, row) => total + BigInt(row.source_size), 0n)),
        }], []];
      }
      throw new Error(`Unexpected SQL: ${sql}`);
    },
    injectAuthHashCollision(uidHash) {
      committed.auth.set(uidHash, { uid: 'different-uid', encoded_payload: '{}',
        payload_hash: '0'.repeat(64) });
    },
    injectSource(value) { committed.source = value; },
  };
  return client;
}

function adapters(client) {
  return {
    importDb: createMySql84ImportAdapter(client, 'clrs_staging'),
    verifyDb: createMySql84VerificationAdapter(client, 'clrs_staging'),
  };
}

const media = {
  async ensure(record) { assert.equal(sha256(record.bytes), record.sha256); },
  async verify(record) { assert.equal(sha256(record.bytes), record.sha256); },
};

test('MySQL staging is exact, idempotent and independently verified', async (t) => {
  const input = await archive(t);
  const client = fakeMySql();
  const { importDb, verifyDb } = adapters(client);
  const common = { ...input, media, beforeWrite: async () => {},
    beforeCommit: async () => {} };
  await stageImport({ ...common, dryRun: false, db: importDb });
  await stageImport({ ...common, dryRun: false, db: importDb });
  const result = await verifyStagedImport({ ...input, db: verifyDb, media,
    beforeRead: async () => {} });
  assert.equal(result.verified, true);
  assert.equal(client.data.auth.size, 1);
  assert.equal(client.data.documents.size, 1);
  assert.equal(client.data.objects.size, 1);
  assert.equal(client.data.documents.get(sha256(documentPath)).firebase_path, documentPath);
  assert.equal(client.data.objects.get(`${source.bucket}\0${sha256(storagePath)}`).source_path,
    storagePath);
  assert.ok(client.calls.some(({ sql }) => sql.includes('START TRANSACTION READ ONLY')));
  assert.ok(client.calls.some(({ sql }) => sql.includes('FOR UPDATE')));
});

test('MySQL source mismatch and generated-hash collision roll back', async (t) => {
  const input = await archive(t);
  const client = fakeMySql();
  client.injectSource({ source_project: 'other-project',
    source_database: source.database, source_bucket: source.bucket });
  const { importDb } = adapters(client);
  await assert.rejects(stageImport({ ...input, db: importDb, media,
    beforeWrite: async () => {}, beforeCommit: async () => {}, dryRun: false }),
  /Firebase source/);
  assert.equal(client.data.auth.size, 0);
  assert.equal(client.data.source.source_project, 'other-project');

  const collision = fakeMySql();
  collision.injectAuthHashCollision(sha256('u1'));
  await assert.rejects(stageImport({ ...input, db: adapters(collision).importDb, media,
    beforeWrite: async () => {}, beforeCommit: async () => {}, dryRun: false }),
  /Auth UID/);
  assert.equal(collision.data.source, null);
  assert.equal(collision.data.documents.size, 0);
});

test('equal SHA-256 index lookups still compare complete document and Storage paths', async (t) => {
  const input = await archive(t);
  let document;
  let object;
  await scanImportArchive({ archivePath: input.archivePath, key: input.key,
    onDocument: (value) => { document = value; },
    onObject: (value) => { object = value; },
  });
  const documentCollision = fakeMySql();
  documentCollision.data.documents.set(sha256(document.firebasePath), {
    firebase_path: `${document.firebasePath}-other`,
    parent_path: document.parentPath, collection_path: document.collectionPath,
    document_id: document.documentId,
    encoded_payload: JSON.stringify(document.encodedPayload),
    payload_hash: document.sha256.toUpperCase(),
  });
  await assert.rejects(stageImport({ ...input, db: adapters(documentCollision).importDb,
    media, beforeWrite: async () => {}, beforeCommit: async () => {}, dryRun: false }),
  /Firestore path/);
  assert.equal(documentCollision.data.source, null);

  const objectCollision = fakeMySql();
  objectCollision.data.objects.set(`${source.bucket}\0${sha256(object.name)}`, {
    source_bucket: source.bucket, source_path: `${object.name}-other`,
    source_metadata: JSON.stringify(object.metadata), source_size: String(object.size),
    source_hash: object.sha256.toUpperCase(), target_key: object.targetKey,
    target_hash: object.sha256.toUpperCase(), copied_at: '2026-09-30 00:00:00',
  });
  await assert.rejects(stageImport({ ...input, db: adapters(objectCollision).importDb,
    media, beforeWrite: async () => {}, beforeCommit: async () => {}, dryRun: false }),
  /Storage path/);
  assert.equal(objectCollision.data.source, null);
});

test('read-back catches changed payload and extra target rows without writing', async (t) => {
  const input = await archive(t);
  const client = fakeMySql();
  const { importDb, verifyDb } = adapters(client);
  await stageImport({ ...input, db: importDb, media,
    beforeWrite: async () => {}, beforeCommit: async () => {}, dryRun: false });
  const authRow = client.data.auth.get(sha256('u1'));
  authRow.encoded_payload = JSON.stringify({ uid: 'u1', email: 'changed@example.invalid' });
  await assert.rejects(verifyStagedImport({ ...input, db: verifyDb, media,
    beforeRead: async () => {} }), /Auth UID/);
  authRow.encoded_payload = JSON.stringify({ uid: 'u1',
    email: 'synthetic@example.invalid', disabled: false });
  client.data.auth.set(sha256('extra'), { uid: 'extra', encoded_payload: '{}',
    payload_hash: '0'.repeat(64) });
  await assert.rejects(verifyStagedImport({ ...input, db: verifyDb, media,
    beforeRead: async () => {} }), /count mismatch/);
  assert.equal(client.calls.filter(({ sql }) => sql.includes('INSERT INTO')).length, 4);
});

test('target guards require clrs_staging, MySQL 8.4, strict utf8mb4 and schema 1', async () => {
  assert.throws(() => createMySql84ImportAdapter(fakeMySql(), 'default_db'),
    /clrs_staging confirmation/);
  const unopened = adapters(fakeMySql());
  await assert.rejects(unopened.importDb.stageAuth({}), /transaction is not open/);
  await assert.rejects(unopened.verifyDb.verifyAuth({}), /transaction is not open/);
  for (const options of [
    { database: 'default_db' }, { version: '8.0.42' },
    { sqlMode: 'NO_ENGINE_SUBSTITUTION', ignoreStrictMode: true }, { charset: 'latin1' },
    { schemaVersion: 2 },
  ]) {
    const client = fakeMySql(options);
    const adapter = createMySql84ImportAdapter(client, 'clrs_staging');
    await assert.rejects(adapter.begin(expectedSource), /mismatch/);
    await adapter.rollback();
    assert.equal(client.data.source, null);
  }
});

test('managed nonstrict defaults are corrected on the pinned connection before transaction', async (t) => {
  const input = await archive(t);
  const client = fakeMySql({ sqlMode: 'IGNORE_SPACE' });
  await stageImport({ ...input, db: adapters(client).importDb, media,
    beforeWrite: async () => {}, beforeCommit: async () => {}, dryRun: false });
  const strictIndex = client.calls.findIndex(({ sql }) => sql.startsWith('SET SESSION sql_mode'));
  const transactionIndex = client.calls.findIndex(({ sql }) => sql === 'START TRANSACTION');
  assert.ok(strictIndex >= 0 && strictIndex < transactionIndex);
  assert.equal(client.calls.some(({ sql }) => /SET GLOBAL/.test(sql)), false);
  assert.equal(client.data.auth.size, 1);
});

function authRecord(uid, extra = {}) {
  const encodedPayload = { uid, disabled: false, ...extra };
  return { uid, encodedPayload, sha256: payloadHash(encodedPayload) };
}

function documentRecord(id, extra = {}) {
  const encodedPayload = { fields: { integer: { integerValue: '9007199254740993' }, ...extra },
    createTime: '2026-10-01T00:00:00Z', updateTime: '2026-10-01T00:00:01Z' };
  return { firebasePath: `users/${id}`, parentPath: null, collectionPath: 'users',
    documentId: id, encodedPayload, sha256: payloadHash(encodedPayload) };
}

test('100-row batches retain exact Unicode identities and drain transitions, counts and commit', async () => {
  const client = fakeMySql();
  const { importDb, verifyDb } = adapters(client);
  const auth = Array.from({ length: 250 }, (_, i) => authRecord(`UID-${i}`));
  auth.splice(0, 4, ...['A', 'a', 'Ä', 'A\u0308'].map((uid) => authRecord(uid)));
  const documents = Array.from({ length: 230 }, (_, i) => documentRecord(`документ-${i}`));
  await importDb.begin(expectedSource);
  for (const record of auth) await importDb.stageAuth(record);
  assert.equal(client.calls.filter(({ sql }) => sql.includes('INSERT INTO clrs_staging.legacy_auth_users')).length, 2);
  for (const record of documents) await importDb.stageDocument(record);
  assert.equal(client.calls.filter(({ sql }) => sql.includes('INSERT INTO clrs_staging.legacy_auth_users')).length, 3);
  assert.equal(client.calls.filter(({ sql }) => sql.includes('INSERT INTO clrs_staging.legacy_documents')).length, 2);
  await importDb.commit();
  assert.equal(client.data.auth.size, 250);
  assert.equal(client.data.documents.size, 230);
  assert.equal(client.calls.filter(({ sql }) => sql.includes('INSERT INTO clrs_staging.legacy_documents')).length, 3);
  for (const record of auth.slice(0, 4)) assert.equal(client.data.auth.get(sha256(record.uid)).uid, record.uid);
  const insertEnd = client.calls.length;
  await verifyDb.begin(expectedSource);
  for (const record of auth) await verifyDb.verifyAuth(record);
  for (const record of documents) await verifyDb.verifyDocument(record);
  await verifyDb.verifyCounts({ authUsers: 250, firestoreDocuments: 230,
    storageObjects: 0, storageBytes: 0 });
  await verifyDb.commit();
  const checks = client.calls.slice(insertEnd);
  assert.equal(checks.filter(({ sql }) => sql.includes('FROM clrs_staging.legacy_auth_users WHERE')).length, 3);
  assert.equal(checks.filter(({ sql }) => sql.includes('FROM clrs_staging.legacy_documents WHERE')).length, 3);
  assert.equal(checks.some(({ sql }) => sql.includes('INSERT INTO')), false);
  for (const call of client.calls.filter(({ sql }) => sql.includes(' IN ('))) assert.ok(call.params.length <= 100);
});

test('packet bounds use UTF-8/JSON worst-case bytes and oversized rows fail without data INSERT', async () => {
  const maxPacket = 8192;
  const client = fakeMySql({ maxPacket });
  const adapter = adapters(client).importDb;
  await adapter.begin(expectedSource);
  const records = Array.from({ length: 15 }, (_, i) => authRecord(`Юзер-${i}`, {
    escaped: '\"\\\n😀'.repeat(30),
  }));
  for (const record of records) await adapter.stageAuth(record);
  await adapter.commit();
  const inserts = client.calls.filter(({ sql }) => sql.includes('INSERT INTO clrs_staging.legacy_auth_users'));
  assert.ok(inserts.length > 1);
  for (const { sql, params } of inserts) {
    assert.ok(params.length / 3 <= 100);
    assert.ok(Buffer.byteLength(sql) + params.reduce((total, value) => total + 2 * Buffer.byteLength(value) + 32, 0)
      <= maxPacket / 2);
  }
  const tooLarge = fakeMySql({ maxPacket });
  const stage = adapters(tooLarge).importDb;
  await stage.begin(expectedSource);
  await assert.rejects(stage.stageDocument(documentRecord('too-large', { text: { stringValue: '😀'.repeat(2000) } })), /packet budget/);
  await assert.rejects(stage.commit(), /rollback is required/);
  await stage.rollback();
  assert.equal(tooLarge.data.source, null);
  assert.equal(tooLarge.calls.some(({ sql }) => sql.includes('INSERT INTO clrs_staging.legacy_documents')), false);
  const verify = adapters(client).verifyDb;
  await verify.begin(expectedSource);
  await assert.rejects(verify.verifyAuth(authRecord('too-large', { text: '😀'.repeat(2000) })), /packet budget/);
  await verify.rollback();
});

test('late retained conflicts poison the transaction and rollback every earlier batch', async () => {
  const client = fakeMySql();
  const record = documentRecord('retained');
  const old = { firebase_path: 'users/other', parent_path: null, collection_path: 'users',
    document_id: 'other', encoded_payload: JSON.stringify(record.encodedPayload),
    payload_hash: record.sha256.toUpperCase() };
  client.data.documents.set(sha256(record.firebasePath), old);
  const adapter = adapters(client).importDb;
  await adapter.begin(expectedSource);
  for (let i = 0; i < 150; i++) await adapter.stageAuth(authRecord(`u${i}`));
  for (let i = 0; i < 150; i++) await adapter.stageDocument(documentRecord(`d${i}`));
  await adapter.stageDocument(record);
  await assert.rejects(adapter.commit(), /Firestore path/);
  await assert.rejects(adapter.flush(), /rollback is required/);
  await adapter.rollback();
  assert.equal(client.data.auth.size, 0);
  assert.equal(client.data.documents.size, 1);
  assert.deepEqual(client.data.documents.get(sha256(record.firebasePath)), old);
  assert.equal(client.calls.some(({ sql }) => sql === 'COMMIT'), false);
});

test('batch matching rejects missing, duplicate, extra, Unicode-swapped and changed typed rows', async () => {
  const transforms = [
    (rows) => rows.slice(1),
    (rows) => [rows[0], rows[0]],
    (rows) => [...rows, { ...rows[0], archive_key: '0'.repeat(64) }],
    (rows) => rows.map((row) => ({ ...row, uid: row.uid.toLowerCase() })),
    (rows) => rows.map((row) => ({ ...row, encoded_payload: JSON.stringify({ uid: row.uid, disabled: 'false' }) })),
  ];
  for (const readTransform of transforms) {
    const client = fakeMySql({ readTransform });
    const adapter = adapters(client).importDb;
    await adapter.begin(expectedSource);
    await adapter.stageAuth(authRecord('A'));
    await adapter.stageAuth(authRecord('Ä'));
    await assert.rejects(adapter.flush(), /Auth UID/);
    await adapter.rollback();
    assert.equal(client.data.auth.size, 0);
  }
});

test('buffer owns its JSON snapshot, drains before object upload and does not retry unknown COMMIT', async (t) => {
  const client = fakeMySql();
  const adapter = adapters(client).importDb;
  const record = authRecord('snapshot', { typed: { integerValue: '42' } });
  await adapter.begin(expectedSource);
  await adapter.stageAuth(record);
  record.encodedPayload.typed.integerValue = 'changed-after-enqueue';
  await adapter.commit();
  assert.equal(JSON.parse(client.data.auth.get(sha256('snapshot')).encoded_payload).typed.integerValue, '42');

  const input = await archive(t);
  const conflict = fakeMySql();
  conflict.data.documents.set(sha256(documentPath), {
    firebase_path: 'other/path', encoded_payload: '{}', payload_hash: '0'.repeat(64),
  });
  let mediaCalls = 0;
  let finalCalls = 0;
  await assert.rejects(stageImport({ ...input, dryRun: false, db: adapters(conflict).importDb,
    media: { async ensure() { mediaCalls++; } }, beforeWrite: async () => {},
    beforeCommit: async () => { finalCalls++; } }), /Firestore path/);
  assert.equal(mediaCalls, 0);
  assert.equal(finalCalls, 0);

  const unknown = fakeMySql({ fault: ({ sql }) => { if (sql === 'COMMIT') throw new Error('Synthetic lost COMMIT response'); } });
  const uncertain = adapters(unknown).importDb;
  await uncertain.begin(expectedSource);
  await uncertain.stageAuth(authRecord('unknown'));
  await assert.rejects(uncertain.commit(), /lost COMMIT/);
  await assert.rejects(uncertain.commit(), /rollback is required/);
  assert.equal(unknown.calls.filter(({ sql }) => sql.includes('INSERT INTO clrs_staging.legacy_auth_users')).length, 1);
  assert.equal(unknown.calls.filter(({ sql }) => sql === 'COMMIT').length, 1);
  await uncertain.rollback();
});

test('failed batch INSERT drains nothing later and read-only count check rejects extra records', async () => {
  const fail = fakeMySql({ fault: ({ sql }) => {
    if (sql.includes('INSERT INTO clrs_staging.legacy_auth_users')) throw new Error('Synthetic batch INSERT failure');
  } });
  const adapter = adapters(fail).importDb;
  await adapter.begin(expectedSource);
  await adapter.stageAuth(authRecord('pending'));
  await assert.rejects(adapter.stageDocument(documentRecord('next-kind')), /batch INSERT/);
  await assert.rejects(adapter.commit(), /rollback is required/);
  await adapter.rollback();
  assert.equal(fail.calls.some(({ sql }) => sql.includes('INSERT INTO clrs_staging.legacy_documents')), false);
  assert.equal(fail.data.source, null);

  const client = fakeMySql();
  const db = adapters(client);
  await db.importDb.begin(expectedSource);
  await db.importDb.stageAuth(authRecord('expected'));
  await db.importDb.commit();
  client.data.auth.set(sha256('extra'), { uid: 'extra', encoded_payload: '{}', payload_hash: '0'.repeat(64) });
  await db.verifyDb.begin(expectedSource);
  await db.verifyDb.verifyAuth(authRecord('expected'));
  await assert.rejects(db.verifyDb.verifyCounts({ authUsers: 1, firestoreDocuments: 0, storageObjects: 0, storageBytes: 0 }), /count mismatch/);
  await db.verifyDb.rollback();
  assert.equal(client.data.auth.size, 2);
});

test('archive without Storage flushes its final partial batch before the private final check', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-mysql84-drain-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const archivePath = join(directory, 'no-objects.clrsenc');
  const key = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(archivePath, key);
  await writer.writeJson(source);
  await writer.writeJson({ kind: 'auth-user', user: authRecord('a').encodedPayload });
  await writer.writeJson({ kind: 'firestore-document', path: 'users/a',
    ...documentRecord('a').encodedPayload });
  await writer.finish({ ...summary, authUsers: 1, firestoreDocuments: 1,
    firestoreMissingParents: 0, firestoreReferences: 1, storageObjects: 0, storageBytes: 0 });
  const client = fakeMySql();
  let checked = false;
  await stageImport({ archivePath, key, expectedSource, dryRun: false,
    db: adapters(client).importDb, media, beforeWrite: async () => {},
    beforeCommit: async () => {
      checked = true;
      assert.ok(client.calls.some(({ sql }) => sql.includes('FROM clrs_staging.legacy_documents WHERE')));
      assert.equal(client.calls.some(({ sql }) => sql === 'COMMIT'), false);
    } });
  assert.equal(checked, true);
  assert.equal(client.data.documents.size, 1);
});
