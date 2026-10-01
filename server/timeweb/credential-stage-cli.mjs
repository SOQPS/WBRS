#!/usr/bin/env node
import { open, readFile, realpath, stat } from 'node:fs/promises';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EncryptedArchiveWriter, readEncryptedArchive } from './encrypted-archive.mjs';
import { privateInput } from './import-cli-common.mjs';
import { privateMysqlConfig } from './apply-mysql84-schema.mjs';
import { createBoundedMysql84Client } from './bounded-mysql84-client.mjs';
import { CREDENTIAL_STAGE_LIMITS, prepareCredentialStage, credentialStageSummary,
  disposeCredentialStage, stageCredentials, verifyStagedCredentials } from './credential-stage-core.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const required = ['--archive', '--key-file', '--credentials', '--credentials-key-file',
  '--manifest', '--hmac-key-file', '--wrapping-key-file', '--config-ref',
  '--project', '--database', '--bucket'];
const limitOptions = new Map([
  ['--max-auth-users', 'maxAuthUsers'], ['--max-firestore-documents', 'maxFirestoreDocuments'],
  ['--max-storage-objects', 'maxStorageObjects'], ['--max-storage-bytes', 'maxStorageBytes'],
  ['--max-object-bytes', 'maxObjectBytes'],
]);
const options = new Set([...required, ...limitOptions.keys(), '--mode', '--config-file', '--ca-file',
  '--confirm-target-db', '--confirm-archive-sha256', '--confirm-credentials-sha256',
  '--confirm-plan-sha256', '--receipt-file']);

export function parseCredentialStageArgs(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    if (!options.has(args[index]) || !args[index + 1] || values.has(args[index])) {
      throw new Error('Invalid credential stage arguments');
    }
    values.set(args[index], args[index + 1]);
  }
  if (required.some((name) => !values.has(name))) throw new Error('Complete private credential/source inputs required');
  const mode = values.get('--mode') ?? 'dry-run';
  if (!['dry-run', 'stage', 'verify'].includes(mode)) throw new Error('Unsupported credential stage mode');
  const limits = {};
  for (const [name, field] of limitOptions) {
    if (values.has(name)) {
      const value = Number(values.get(name));
      if (!Number.isSafeInteger(value) || value < 1 || value > CREDENTIAL_STAGE_LIMITS[field]) {
        throw new Error('Credential stage limit exceeds the reviewed bound');
      }
      limits[field] = value;
    }
  }
  if (mode !== 'dry-run' && (!values.has('--config-file') || !values.has('--ca-file')
      || values.get('--confirm-target-db') !== 'clrs_staging'
      || ['--confirm-archive-sha256', '--confirm-credentials-sha256', '--confirm-plan-sha256']
        .some((name) => !/^[a-f0-9]{64}$/.test(values.get(name) ?? '')))) {
    throw new Error('Explicit staging database and authenticated hashes required');
  }
  if (mode === 'stage' && !values.has('--receipt-file')) throw new Error('A new durable encrypted receipt is required');
  return { values, mode, limits };
}

async function boundedInput(path, label, maxBytes) {
  if (typeof path !== 'string' || path.includes('.partial')) throw new Error('Incomplete private input refused');
  const result = await privateInput(path, label);
  if ((await stat(result)).size > maxBytes) throw new Error('Private input exceeds its reviewed size bound');
  return result;
}
async function receiptOutput(path, inputPaths) {
  if (typeof path !== 'string' || !isAbsolute(path) || path.includes('.partial')) throw new Error('Private absolute receipt path required');
  const parent = await realpath(dirname(path));
  const portion = relative(await realpath(repository), parent);
  if (!(portion === '..' || portion.startsWith(`..${sep}`) || isAbsolute(portion))) throw new Error('Receipt must stay outside Git');
  const info = await stat(parent);
  if (!info.isDirectory() || (info.mode & 0o077) !== 0) throw new Error('Private receipt directory required');
  const output = resolve(parent, basename(path));
  if (inputPaths.includes(output)) throw new Error('Receipt cannot replace a source or key');
  try { await stat(output); } catch (error) { if (error.code === 'ENOENT') return output; throw error; }
  throw new Error('Receipt already exists; reconcile its outcome before retrying');
}
export async function writeCredentialStageReceipt(path, key, receipt) {
  const writer = await EncryptedArchiveWriter.create(path, key);
  try {
    await writer.writeJson(receipt);
    await writer.finish({ receiptRecords: 1 });
    const directory = await open(dirname(path), 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  } catch (error) { await writer.abort().catch(() => {}); throw error; }
}
export async function readCredentialStageReceipt(path, key) {
  let record; let complete = false;
  for await (const frame of readEncryptedArchive(await boundedInput(path, 'Credential receipt', 1024 * 1024), key)) {
    if (frame.type !== 'json') throw new Error('Invalid credential receipt frame');
    if (!record && !complete && frame.record.kind === 'clrs-credential-stage-receipt') record = frame.record;
    else if (record && !complete && frame.record.kind === 'end'
        && frame.record.summary?.receiptRecords === 1) complete = true;
    else throw new Error('Unexpected credential receipt order');
  }
  if (!record || !complete) throw new Error('Incomplete credential receipt');
  return record;
}

// Real SQL is opened only after the full archive, FINAL manifest and credential
// bundle have been authenticated. No Firebase/Timeweb API call is made here.
export async function mainCredentialStage(args = process.argv.slice(2)) {
  const { values, mode, limits } = parseCredentialStageArgs(args);
  const keys = []; let plan; let client;
  try {
    const paths = {};
    for (const [name, label, bound] of [
      ['--archive', 'Full archive', Number.MAX_SAFE_INTEGER],
      ['--key-file', 'Full archive key', 32], ['--credentials', 'Credential bundle', 20 * 1024 * 1024],
      ['--credentials-key-file', 'Credential archive key', 32],
      ['--manifest', 'FINAL manifest', 64 * 1024 * 1024],
      ['--hmac-key-file', 'Manifest HMAC key', 32], ['--wrapping-key-file', 'Credential wrapping key', 32],
    ]) paths[name] = await boundedInput(values.get(name), label, bound);
    if (new Set(Object.values(paths)).size !== Object.values(paths).length) throw new Error('Separate private inputs required');
    for (const name of ['--key-file', '--credentials-key-file', '--hmac-key-file', '--wrapping-key-file']) {
      const key = await readFile(paths[name]); keys.push(key);
      if (key.length !== 32) throw new Error('Keys must contain exactly 32 random bytes');
    }
    const [key, credentialKey, hmacKey, wrappingKey] = keys;
    if ([key, credentialKey, hmacKey].some((other) => wrappingKey.equals(other))) throw new Error('Server wrapping key must be separate from export keys');
    plan = await prepareCredentialStage({ archivePath: paths['--archive'], key,
      credentialArchivePath: paths['--credentials'], credentialKey,
      manifest: JSON.parse(await readFile(paths['--manifest'], 'utf8')), hmacKey, wrappingKey,
      configRef: values.get('--config-ref'), limits,
      expectedSource: { project: values.get('--project'), database: values.get('--database'), bucket: values.get('--bucket') },
    });
    if (mode === 'dry-run') return credentialStageSummary(plan);
    const confirmations = { targetDatabase: values.get('--confirm-target-db'),
      archiveSha256: values.get('--confirm-archive-sha256'),
      credentialArchiveSha256: values.get('--confirm-credentials-sha256'),
      planSha256: values.get('--confirm-plan-sha256') };
    if (confirmations.archiveSha256 !== plan.archiveSha256 || confirmations.credentialArchiveSha256 !== plan.credentialArchiveSha256
        || confirmations.planSha256 !== plan.planSha256) throw new Error('Confirmed sources do not match the authenticated plan');
    let output; let receipt;
    if (mode === 'stage') output = await receiptOutput(values.get('--receipt-file'), Object.values(paths));
    else if (values.has('--receipt-file')) receipt = await readCredentialStageReceipt(values.get('--receipt-file'), credentialKey);
    const config = await privateMysqlConfig(values);
    const mysql = await import('mysql2/promise');
    client = createBoundedMysql84Client(await mysql.createConnection(config));
    if (mode === 'stage') return await stageCredentials(client, plan, confirmations,
      (record) => writeCredentialStageReceipt(output, credentialKey, record));
    return await verifyStagedCredentials(client, plan, confirmations.targetDatabase, receipt);
  } finally {
    await client?.end().catch(() => {});
    if (plan) disposeCredentialStage(plan);
    keys.forEach((key) => key.fill(0));
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  mainCredentialStage().then((result) => process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)).catch(() => {
    // Driver/parse errors can contain email, source rows or authentication data.
    process.stderr.write('Credential stage failed. If a receipt exists, use receipt-bound verify before retrying; do not delete or overwrite credentials.\n');
    process.exitCode = 1;
  });
}
