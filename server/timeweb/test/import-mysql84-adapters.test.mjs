import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { scanImportArchive } from '../import-core.mjs';
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
  charset = 'utf8mb4', schemaVersion = 1 } = {}) {
  let committed = emptyTables();
  let working = null;
  let readOnly = false;
  const calls = [];
  const client = {
    get data() { return committed; },
    calls,
    async query(sql) {
      calls.push({ sql });
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
      if (sql.includes('SELECT DATABASE()')) {
        return [[{ target_database: database, mysql_version: version,
          sql_mode: sqlMode, character_set_connection: charset }], []];
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
        const [uid, encodedPayload, payloadHash] = params;
        const key = sha256(uid);
        if (!working.auth.has(key)) working.auth.set(key, {
          uid, encoded_payload: encodedPayload, payload_hash: payloadHash.toUpperCase(),
        });
        return [{ affectedRows: 1 }, []];
      }
      if (sql.includes('FROM clrs_staging.legacy_auth_users WHERE')) {
        const row = working.auth.get(params[0]);
        return [row ? [row] : [], []];
      }
      if (sql.includes('INSERT INTO clrs_staging.legacy_documents')) {
        assert.equal(readOnly, false);
        const [firebasePath, parentPath, collectionPath, documentId,
          encodedPayload, payloadHash] = params;
        const key = sha256(firebasePath);
        if (!working.documents.has(key)) working.documents.set(key, {
          firebase_path: firebasePath, parent_path: parentPath,
          collection_path: collectionPath, document_id: documentId,
          encoded_payload: encodedPayload, payload_hash: payloadHash.toUpperCase(),
        });
        return [{ affectedRows: 1 }, []];
      }
      if (/FROM clrs_staging\.legacy_documents\s+WHERE/.test(sql)) {
        const row = working.documents.get(params[0]);
        return [row ? [row] : [], []];
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
    { sqlMode: 'NO_ENGINE_SUBSTITUTION' }, { charset: 'latin1' },
    { schemaVersion: 2 },
  ]) {
    const client = fakeMySql(options);
    const adapter = createMySql84ImportAdapter(client, 'clrs_staging');
    await assert.rejects(adapter.begin(expectedSource), /mismatch/);
    await adapter.rollback();
    assert.equal(client.data.source, null);
  }
});
