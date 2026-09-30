#!/usr/bin/env node
import { open, readFile, realpath } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { privateInput } from './import-cli-common.mjs';
import { mysql84Config } from './import-mysql84-cli-config.mjs';
import { applyReviewedSchema, reviewedSchema, schemaPreflight,
  SCHEMA_SHA256, TARGET_DATABASE } from './mysql84-schema-core.mjs';

const allowed = new Set(['--config-file', '--ca-file', '--backup-file', '--mode', '--confirm-target-db']);
export function parseSchemaArgs(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    if (!allowed.has(args[index]) || !args[index + 1] || values.has(args[index])) {
      throw new Error('Invalid schema arguments');
    }
    values.set(args[index], args[index + 1]);
  }
  const mode = values.get('--mode') ?? 'check';
  if (!['check', 'apply'].includes(mode) || !values.get('--config-file')
      || !values.get('--ca-file') || values.get('--confirm-target-db') !== TARGET_DATABASE
      || (mode === 'apply' && !values.get('--backup-file'))) {
    throw new Error('Schema target and mode must be confirmed');
  }
  return { values, mode };
}

export async function privateMysqlConfig(values) {
  let config;
  try { config = JSON.parse(await readFile(await privateInput(values.get('--config-file'), 'Database config'), 'utf8')); }
  catch { throw new Error('Invalid private database config'); }
  return mysql84Config(values, {
    MYSQL_HOST: config?.host, MYSQL_PORT: String(config?.port ?? ''),
    MYSQL_USER: config?.user, MYSQL_PASSWORD: config?.password,
    MYSQL_DATABASE: config?.database, MYSQL_CA_FILE: values.get('--ca-file'),
  });
}

async function createJournal(path, journal) {
  if (!isAbsolute(path)) throw new Error('Backup path must be absolute');
  const parent = await realpath(dirname(path));
  const root = await realpath(dirname(dirname(dirname(fileURLToPath(import.meta.url)))));
  const portion = relative(root, parent);
  if (!(portion === '..' || portion.startsWith(`..${sep}`) || isAbsolute(portion))) {
    throw new Error('Backup must be outside the repository');
  }
  const handle = await open(resolve(parent, path.split(sep).at(-1)), 'wx', 0o600);
  async function save(value) {
    const data = Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
    await handle.truncate(0);
    let offset = 0;
    while (offset < data.length) {
      const { bytesWritten } = await handle.write(data, offset, data.length - offset, offset);
      if (bytesWritten < 1) throw new Error('Private journal write failed');
      offset += bytesWritten;
    }
    await handle.sync();
  }
  try { await save(journal); }
  catch (error) { await handle.close(); throw error; }
  return { save, close: () => handle.close() };
}

export async function main(args = process.argv.slice(2)) {
  const { values, mode } = parseSchemaArgs(args);
  const schema = reviewedSchema(await readFile(new URL('./db/001_initial_mysql84.sql', import.meta.url), 'utf8'));
  const config = await privateMysqlConfig(values);
  const mysql = await import('mysql2/promise');
  let database;
  let backup;
  try {
    database = await mysql.createConnection(config);
    const preflight = await schemaPreflight(database);
    if (mode === 'check') return { mode, preflightPassed: true, tables: 0, schemaSha256: SCHEMA_SHA256 };
    const journal = { format: 'clrs-mysql-empty-schema-journal-v1',
      createdAt: new Date().toISOString(), schemaSha256: SCHEMA_SHA256,
      preflight, status: 'pre_ddl_backup_complete', executedStatements: 0, nextStatement: 1 };
    backup = await createJournal(values.get('--backup-file'), journal);
    const result = await applyReviewedSchema({ database, schema,
      saveJournal: backup.save, journal });
    return { mode, ...result, schemaSha256: SCHEMA_SHA256 };
  } finally {
    if (backup) await backup.close().catch(() => {});
    if (database) await database.end().catch(() => {});
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().then((result) => process.stdout.write(`${JSON.stringify(result)}\n`)).catch(() => {
    // Never log SQL/driver errors: they can include authentication context.
    process.stderr.write('CLRS MySQL schema operation failed; inspect the private journal. Do not automatically rerun.\n');
    process.exitCode = 1;
  });
}
