import { createHash } from 'node:crypto';

export const TARGET_DATABASE = 'clrs_staging';
export const SCHEMA_SHA256 = '069cc1a473475a85742c71387374da44ca5483abd219c00affb9cc9ce739f621';
const REQUIRED_PRIVILEGES = ['CREATE', 'INSERT', 'REFERENCES', 'SELECT', 'UPDATE'];

// Accept only the reviewed, immutable v1 DDL. No arbitrary SQL input is allowed.
export function reviewedSchema(sql) {
  if (typeof sql !== 'string'
      || createHash('sha256').update(sql).digest('hex') !== SCHEMA_SHA256) {
    throw new Error('Schema does not match the reviewed migration');
  }
  const uncommented = sql.replace(/^\s*--[^\n]*$/gm, '');
  const statements = uncommented.split(';').map((value) => value.trim()).filter(Boolean);
  const tables = statements.flatMap((statement) => {
    const match = /^CREATE TABLE clrs_staging\.([a-z_]+) \(/.exec(statement);
    return match ? [match[1]] : [];
  });
  if (statements.length !== 45 || tables.length !== 42 || new Set(tables).size !== 42
      || (uncommented.match(/FOREIGN KEY \(/g) ?? []).length !== 66) {
    throw new Error('Unexpected reviewed schema structure');
  }
  return { statements, tables: tables.sort() };
}

export function assertMigrationGrants(rows) {
  if (!Array.isArray(rows) || !rows.length) throw new Error('Migration grants unavailable');
  const privileges = new Set();
  let usage = false;
  for (const row of rows) {
    const values = Object.values(row);
    if (values.length !== 1 || typeof values[0] !== 'string') {
      throw new Error('Invalid migration grant response');
    }
    const grant = values[0];
    const match = /^GRANT ([A-Z ,]+) ON (\*\.\*|`clrs_staging`\.\*) TO (?:`[^`]+`|'[^']+')@(?:`[^`]+`|'[^']+')$/.exec(grant);
    if (!match) throw new Error('Unexpected migration grant scope or option');
    const names = match[1].split(',').map((value) => value.trim());
    if (match[2] === '*.*') {
      if (names.length !== 1 || names[0] !== 'USAGE' || usage) {
        throw new Error('Global migration privileges are forbidden');
      }
      usage = true;
    } else {
      for (const name of names) {
        if (!REQUIRED_PRIVILEGES.includes(name) || privileges.has(name)) {
          throw new Error('Unexpected migration database privilege');
        }
        privileges.add(name);
      }
    }
  }
  if (!usage || REQUIRED_PRIVILEGES.some((name) => !privileges.has(name))) {
    throw new Error('Missing required migration privileges');
  }
  return REQUIRED_PRIVILEGES;
}

export async function schemaPreflight(database) {
  const [grants] = await database.query('SHOW GRANTS');
  assertMigrationGrants(grants);
  let denied = false;
  try { await database.query('USE default_db'); }
  catch (error) {
    if (error?.code === 'ER_DBACCESS_DENIED_ERROR' && error?.errno === 1044) denied = true;
    else throw new Error('Cannot confirm legacy database isolation');
  }
  if (!denied) throw new Error('Legacy database access must be denied');
  // Managed service defaults are not strict. Set only this connection; never
  // alter global SQL mode or another application's connection behavior.
  await database.query("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'");
  const [[server]] = await database.query(
    'SELECT DATABASE() AS active_database, VERSION() AS mysql_version, @@innodb_page_size AS page_size, @@session.sql_mode AS sql_mode, @@character_set_connection AS charset');
  if (server?.active_database !== TARGET_DATABASE
      || !/^8\.4\./.test(server?.mysql_version ?? '')
      || Number(server?.page_size) !== 16384 || server?.charset !== 'utf8mb4'
      || !(server?.sql_mode ?? '').split(',').includes('STRICT_TRANS_TABLES')) {
    throw new Error('Unexpected migration server configuration');
  }
  const [[tls]] = await database.query("SHOW SESSION STATUS LIKE 'Ssl_cipher'");
  if (typeof tls?.Value !== 'string' || !tls.Value) throw new Error('Database TLS is required');
  const [[objects]] = await database.execute(
    `SELECT (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ?) AS tables_found,
     (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = ?) AS routines_found,
     (SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema = ?) AS triggers_found,
     (SELECT COUNT(*) FROM information_schema.events WHERE event_schema = ?) AS events_found`,
    Array(4).fill(TARGET_DATABASE));
  if (Object.values(objects ?? {}).length !== 4
      || Object.values(objects).some((value) => Number(value) !== 0)) {
    throw new Error('Target is not empty; automatic schema rerun is forbidden');
  }
  return { database: TARGET_DATABASE, mysqlVersion: server.mysql_version,
    pageSize: 16384, tls: true, legacyDatabaseAccess: 'denied',
    privileges: REQUIRED_PRIVILEGES, tables: [], routines: [], triggers: [], events: [] };
}

export async function verifyAppliedSchema(database, expectedTables) {
  const [tables] = await database.execute(
    'SELECT table_name AS name, engine AS engine, table_collation AS collation, row_format AS format FROM information_schema.tables WHERE table_schema = ? ORDER BY table_name',
    [TARGET_DATABASE]);
  if (tables.length !== 42 || tables.some((row, index) => row.name !== expectedTables[index]
      || row.engine !== 'InnoDB' || row.collation !== 'utf8mb4_0900_bin'
      || row.format !== 'Dynamic')) {
    throw new Error('Created schema table verification failed');
  }
  const [[foreignKeys]] = await database.execute(
    'SELECT COUNT(*) AS total FROM information_schema.referential_constraints WHERE constraint_schema = ?',
    [TARGET_DATABASE]);
  const [[markers]] = await database.query(
    `SELECT (SELECT COUNT(*) FROM clrs_staging.schema_migrations WHERE version = 1) AS version_markers,
     (SELECT COUNT(*) FROM clrs_staging.event_counter WHERE singleton = 1 AND last_id = 0) AS event_counters`);
  if (Number(foreignKeys?.total) !== 66 || Number(markers?.version_markers) !== 1
      || Number(markers?.event_counters) !== 1) throw new Error('Created schema marker verification failed');
  for (const name of expectedTables) {
    const [[count]] = await database.query(`SELECT COUNT(*) AS total FROM clrs_staging.${name}`);
    const expected = ['event_counter', 'schema_migrations'].includes(name) ? 1 : 0;
    if (Number(count?.total) !== expected) throw new Error('Unexpected data in the created schema');
  }
  return { tables: 42, foreignKeys: 66, schemaVersion: 1, appRows: 0, archiveRows: 0 };
}

export async function applyReviewedSchema({ database, schema, saveJournal, journal }) {
  for (let index = 0; index < schema.statements.length; index += 1) {
    journal.nextStatement = index + 1;
    await saveJournal(journal);
    try { await database.query(schema.statements[index]); }
    catch (error) {
      journal.status = 'failed_manual_review_required';
      journal.errorCode = /^[A-Z0-9_]+$/.test(error?.code ?? '') ? error.code : 'UNKNOWN';
      await saveJournal(journal);
      throw new Error('Schema stopped at first failure; do not automatically rerun');
    }
    journal.executedStatements = index + 1;
  }
  journal.status = 'verifying';
  await saveJournal(journal);
  const result = await verifyAppliedSchema(database, schema.tables);
  journal.status = 'applied_verified';
  journal.result = result;
  journal.finishedAt = new Date().toISOString();
  await saveJournal(journal);
  return result;
}
