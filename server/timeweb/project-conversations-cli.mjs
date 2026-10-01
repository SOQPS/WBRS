#!/usr/bin/env node
import { open, readFile, realpath, stat } from 'node:fs/promises';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { privateInput } from './import-cli-common.mjs';
import { privateMysqlConfig } from './apply-mysql84-schema.mjs';
import { createBoundedMysql84Client } from './bounded-mysql84-client.mjs';
import { EncryptedArchiveWriter, readEncryptedArchive } from './encrypted-archive.mjs';
import { assertPreparedConversationPlan, conversationProjectionSummary,
  prepareConversationProjection } from './project-conversations-core.mjs';
import { assertConversationConfirmations, stageConversationProjection,
  verifyConversationProjection } from './project-conversations-mysql84.mjs';

const repository = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const numericOptions = new Map([
  ['--max-auth-users', 'maxAuthUsers'], ['--max-firestore-documents', 'maxFirestoreDocuments'],
  ['--max-retained-json-bytes', 'maxRetainedJsonBytes'], ['--max-storage-objects', 'maxStorageObjects'],
  ['--max-storage-bytes', 'maxStorageBytes'], ['--max-object-bytes', 'maxObjectBytes'],
]);
const allowed = new Set(['--mode', '--archive', '--key-file', '--project', '--database', '--bucket',
  '--config-file', '--ca-file', '--receipt-file', '--receipt-key-file', '--confirm-target-db',
  '--confirm-archive-sha256', '--confirm-projection-sha256', '--confirm-dependency-sha256',
  '--ack-raw-only-documents', '--ack-raw-only-participant-entries', '--ack-raw-only-reason-digest',
  ...numericOptions.keys()]);
const unsigned = (value) => typeof value === 'string' && /^(0|[1-9]\d*)$/.test(value)
  && Number.isSafeInteger(Number(value));
const sha = (value) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);

export function parseConversationArgs(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    if (!allowed.has(args[index]) || typeof args[index + 1] !== 'string' || !args[index + 1]
        || values.has(args[index])) throw new Error('Invalid conversation CLI arguments');
    values.set(args[index], args[index + 1]);
  }
  const mode = values.get('--mode') ?? 'dry-run';
  if (!['dry-run', 'stage', 'verify'].includes(mode)
      || ['--archive', '--key-file', '--project', '--database', '--bucket'].some((key) => !values.has(key))) {
    throw new Error('Completed FULL archive and source confirmations required');
  }
  const limits = {};
  for (const [option, key] of numericOptions) {
    if (values.has(option)) {
      if (!unsigned(values.get(option)) || Number(values.get(option)) < 1) throw new Error('Invalid conversation bound');
      limits[key] = Number(values.get(option));
    }
  }
  if (mode !== 'dry-run' && (values.get('--confirm-target-db') !== 'clrs_staging'
      || ['--config-file', '--ca-file', '--receipt-file', '--receipt-key-file'].some((key) => !values.has(key))
      || ['--confirm-archive-sha256', '--confirm-projection-sha256', '--confirm-dependency-sha256',
        '--ack-raw-only-reason-digest'].some((key) => !sha(values.get(key)))
      || ['--ack-raw-only-documents', '--ack-raw-only-participant-entries'].some((key) => !unsigned(values.get(key))))) {
    throw new Error('Staging/source/dependency/raw-only acknowledgements and private receipt required');
  }
  return { mode, values, limits };
}
async function input(path, label, maxBytes = Number.MAX_SAFE_INTEGER) {
  if (typeof path !== 'string' || path.includes('.partial')) throw new Error('Partial private input refused');
  const result = await privateInput(path, label);
  if ((await stat(result)).size > maxBytes) throw new Error('Private input exceeds reviewed bound');
  return result;
}
async function output(path, sources) {
  if (typeof path !== 'string' || !isAbsolute(path) || path.includes('.partial')) throw new Error('Private absolute receipt path required');
  const parent = await realpath(dirname(path));
  const portion = relative(await realpath(repository), parent);
  if (!(portion === '..' || portion.startsWith(`..${sep}`) || isAbsolute(portion))) throw new Error('Receipt must stay outside Git');
  const info = await stat(parent);
  if (!info.isDirectory() || (info.mode & 0o077) !== 0) throw new Error('Private receipt directory required');
  const pathResolved = resolve(parent, basename(path));
  if (sources.includes(pathResolved)) throw new Error('Receipt cannot replace source or key');
  try { await stat(pathResolved); }
  catch (error) { if (error.code === 'ENOENT') return pathResolved; throw error; }
  throw new Error('Receipt already exists; use receipt-bound verify before any retry');
}
export async function writeConversationReceipt(path, key, receipt) {
  const writer = await EncryptedArchiveWriter.create(path, key);
  try {
    await writer.writeJson(receipt);
    await writer.finish({ receiptRecords: 1 });
    const parent = await open(dirname(path), 'r');
    try { await parent.sync(); } finally { await parent.close(); }
  } catch (error) { await writer.abort().catch(() => {}); throw error; }
}
export async function readConversationReceipt(path, key) {
  let record; let complete = false;
  for await (const frame of readEncryptedArchive(await input(path, 'Conversation receipt', 1024 * 1024), key)) {
    if (frame.type !== 'json') throw new Error('Invalid conversation receipt frame');
    if (!record && !complete && frame.record.kind === 'clrs-conversation-projection-receipt') record = frame.record;
    else if (record && !complete && frame.record.kind === 'end' && frame.record.summary?.receiptRecords === 1) complete = true;
    else throw new Error('Unexpected conversation receipt order');
  }
  if (!record || !complete) throw new Error('Incomplete conversation receipt');
  return record;
}
export async function mainConversationProjection(args = process.argv.slice(2)) {
  const { values, mode, limits } = parseConversationArgs(args);
  const keys = []; let client;
  try {
    const archivePath = await input(values.get('--archive'), 'Completed full archive');
    const keyPath = await input(values.get('--key-file'), 'Full archive key', 32);
    if (archivePath === keyPath) throw new Error('Archive and key must be separate');
    const key = await readFile(keyPath); keys.push(key);
    if (key.length !== 32) throw new Error('Full archive key must contain 32 bytes');
    const plan = await prepareConversationProjection({ archivePath, key, limits,
      expectedSource: { project: values.get('--project'), database: values.get('--database'), bucket: values.get('--bucket') } });
    // Every CLI mode reads/authenticates the FULL source. Metadata remains
    // available only through the offline planning core, never a SQL command.
    assertPreparedConversationPlan(plan);
    if (mode === 'dry-run') return conversationProjectionSummary(plan);
    const confirmations = { targetDatabase: values.get('--confirm-target-db'),
      archiveSha256: values.get('--confirm-archive-sha256'), projectionSha256: values.get('--confirm-projection-sha256'),
      dependencySha256: values.get('--confirm-dependency-sha256'),
      rawOnlyDocuments: Number(values.get('--ack-raw-only-documents')),
      rawOnlyParticipantEntries: Number(values.get('--ack-raw-only-participant-entries')),
      rawOnlyReasonDigest: values.get('--ack-raw-only-reason-digest') };
    assertConversationConfirmations(plan, confirmations);
    const receiptKeyPath = await input(values.get('--receipt-key-file'), 'Separate receipt key', 32);
    if ([archivePath, keyPath].includes(receiptKeyPath)) throw new Error('Separate receipt key required');
    const receiptKey = await readFile(receiptKeyPath); keys.push(receiptKey);
    if (receiptKey.length !== 32 || receiptKey.equals(key)) throw new Error('Separate 32-byte receipt key required');
    let receipt; let receiptPath;
    if (mode === 'stage') receiptPath = await output(values.get('--receipt-file'), [archivePath, keyPath, receiptKeyPath]);
    else receipt = await readConversationReceipt(values.get('--receipt-file'), receiptKey);
    // No network connection is opened before source, acknowledgements and
    // receipt gates have all passed. Config enforces CA + DNS identity TLS.
    const config = await privateMysqlConfig(values);
    const mysql = await import('mysql2/promise');
    client = createBoundedMysql84Client(await mysql.createConnection(config));
    if (mode === 'stage') return await stageConversationProjection(client, plan, confirmations,
      (record) => writeConversationReceipt(receiptPath, receiptKey, record));
    return await verifyConversationProjection(client, plan, confirmations, receipt);
  } finally {
    await client?.end().catch(() => {});
    keys.forEach((key) => key.fill(0));
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  mainConversationProjection().then((result) => process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)).catch(() => {
    // Driver/JSON errors may contain source content or authentication data.
    process.stderr.write('Conversation projection failed. Preserve any receipt and use receipt-bound verify before retrying. No source records are printed.\n');
    process.exitCode = 1;
  });
}
