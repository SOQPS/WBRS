import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { applyReviewedSchema, assertMigrationGrants, reviewedSchema,
  schemaPreflight, verifyAppliedSchema } from '../mysql84-schema-core.mjs';
import { parseSchemaArgs } from '../apply-mysql84-schema.mjs';

const grants = [
  { grant: 'GRANT USAGE ON *.* TO `synthetic`@`%`' },
  { grant: 'GRANT SELECT, INSERT, UPDATE, CREATE, REFERENCES ON `clrs_staging`.* TO `synthetic`@`%`' },
];
const sql = await readFile(new URL('../db/001_initial_mysql84.sql', import.meta.url), 'utf8');
const schema = reviewedSchema(sql);

function preflightDatabase({ grantRows = grants, denyLegacy = true, tableCount = 0 } = {}) {
  const calls = [];
  return {
    calls,
    async query(statement) {
      calls.push(statement);
      if (statement === 'SHOW GRANTS') return [grantRows];
      if (statement === 'USE default_db') {
        if (denyLegacy) throw Object.assign(new Error('synthetic access denial'),
          { code: 'ER_DBACCESS_DENIED_ERROR', errno: 1044 });
        return [[], []];
      }
      if (statement.startsWith('SET SESSION sql_mode')) return [[], []];
      if (statement.startsWith('SELECT DATABASE()')) return [[{
        active_database: 'clrs_staging', mysql_version: '8.4.4', page_size: 16384,
        sql_mode: 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION', charset: 'utf8mb4',
      }]];
      if (statement.startsWith('SHOW SESSION STATUS')) return [[{ Value: 'TLS_AES_256_GCM_SHA384' }]];
      throw new Error('Unexpected synthetic query');
    },
    async execute() { return [[{ tables_found: tableCount, routines_found: 0, triggers_found: 0, events_found: 0 }]]; },
  };
}

test('schema is pinned to the reviewed DDL and arbitrary SQL changes are rejected', () => {
  assert.equal(schema.statements.length, 45);
  assert.equal(schema.tables.length, 42);
  assert.throws(() => reviewedSchema(`${sql}\nDROP DATABASE default_db;`), /reviewed migration/);
});

test('grant gate rejects missing, global, extra-scope, grant-option and role rights', () => {
  assert.deepEqual(assertMigrationGrants(grants), ['CREATE', 'INSERT', 'REFERENCES', 'SELECT', 'UPDATE']);
  assert.throws(() => assertMigrationGrants([grants[0]]), /Missing required/);
  for (const invalid of [
    'GRANT SELECT ON *.* TO `synthetic`@`%`',
    'GRANT DELETE ON `clrs_staging`.* TO `synthetic`@`%`',
    'GRANT SELECT ON `default_db`.* TO `synthetic`@`%`',
    `${grants[1].grant} WITH GRANT OPTION`,
    'GRANT `administrator`@`%` TO `synthetic`@`%`',
    'GRANT SELECT ON `clrs_staging`.`accounts` TO `synthetic`@`%`',
  ]) assert.throws(() => assertMigrationGrants([...grants, { grant: invalid }]));
});

test('missing target grants stop before even probing default_db', async () => {
  const database = preflightDatabase({ grantRows: [grants[0]] });
  await assert.rejects(schemaPreflight(database), /Missing required/);
  assert.deepEqual(database.calls, ['SHOW GRANTS']);
});

test('legacy database access or pre-existing objects forbid DDL', async () => {
  await assert.rejects(schemaPreflight(preflightDatabase({ denyLegacy: false })), /must be denied/);
  await assert.rejects(schemaPreflight(preflightDatabase({ tableCount: 1 })), /not empty/);
  const result = await schemaPreflight(preflightDatabase());
  assert.equal(result.legacyDatabaseAccess, 'denied');
  assert.deepEqual(result.tables, []);
});

test('first DDL failure stops immediately without retry and records only error code', async () => {
  const calls = [];
  const saved = [];
  const database = {
    async query(statement) {
      calls.push(statement);
      if (calls.length === 3) throw Object.assign(new Error('private SQL context'), { code: 'ER_SYNTHETIC' });
    },
  };
  const journal = { executedStatements: 0 };
  await assert.rejects(applyReviewedSchema({ database, schema, journal,
    saveJournal: async (value) => saved.push(structuredClone(value)) }), /first failure/);
  assert.equal(calls.length, 3);
  assert.equal(journal.executedStatements, 2);
  assert.equal(journal.nextStatement, 3);
  assert.equal(journal.status, 'failed_manual_review_required');
  assert.equal(journal.errorCode, 'ER_SYNTHETIC');
  assert.equal(JSON.stringify(saved).includes('private SQL context'), false);
});

test('final verification checks all tables, all row counts and FK/marker counts', async () => {
  let countCalls = 0;
  const database = {
    async execute(statement) {
      if (statement.startsWith('SELECT table_name')) return [schema.tables.map((name) => ({
        name, engine: 'InnoDB', collation: 'utf8mb4_0900_bin', format: 'Dynamic',
      }))];
      return [[{ total: 66 }]];
    },
    async query(statement) {
      if (statement.startsWith('SELECT (SELECT')) return [[{ version_markers: 1, event_counters: 1 }]];
      countCalls += 1;
      return [[{ total: /\.(event_counter|schema_migrations)$/.test(statement) ? 1 : 0 }]];
    },
  };
  assert.deepEqual(await verifyAppliedSchema(database, schema.tables), {
    tables: 42, foreignKeys: 66, schemaVersion: 1, appRows: 0, archiveRows: 0,
  });
  assert.equal(countCalls, 42);
});

test('CLI requires explicit target and pre-DDL backup for apply', () => {
  const args = ['--config-file', '/private/mysql.json', '--ca-file', '/private/ca.pem',
    '--confirm-target-db', 'clrs_staging'];
  assert.equal(parseSchemaArgs(args).mode, 'check');
  assert.throws(() => parseSchemaArgs([...args, '--mode', 'apply']));
  assert.equal(parseSchemaArgs([...args, '--mode', 'apply', '--backup-file', '/private/empty.json']).mode, 'apply');
  assert.throws(() => parseSchemaArgs([...args, '--mode', 'check', '--mode', 'apply']));
  assert.throws(() => parseSchemaArgs([...args, '--password', 'forbidden']));
});
