import { open, realpath, stat } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EncryptedArchiveWriter, readEncryptedArchive } from './encrypted-archive.mjs';
import { loadImportInputs, privateInput } from './import-cli-common.mjs';
import { mysql84Config } from './import-mysql84-cli-config.mjs';
import { prepareProfileProjection, profileProjectionSummary } from './project-profiles-core.mjs';
import { rollbackProfileProjection, stageProfileProjection, verifyProfileProjection } from './project-profiles-mysql84.mjs';

const repository = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const options = new Set(['--archive', '--key-file', '--project', '--database', '--bucket',
  '--mode', '--confirm-target-db', '--confirm-archive-sha256', '--receipt-file',
  '--ack-orphan-profiles', '--ack-accounts-without-profile', '--confirm-rollback-archive-sha256',
  '--max-auth-users', '--max-firestore-documents']);

export function parseProfileProjectionArgs(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    if (!options.has(args[index]) || !args[index + 1] || values.has(args[index])) {
      throw new Error('Invalid profile projection arguments');
    }
    values.set(args[index], args[index + 1]);
  }
  for (const name of ['--archive', '--key-file', '--project', '--database', '--bucket']) {
    if (!values.has(name)) throw new Error('Missing projection source confirmation');
  }
  const mode = values.get('--mode') ?? 'dry-run';
  if (!['dry-run', 'stage', 'verify', 'rollback'].includes(mode)) throw new Error('Invalid projection mode');
  const limits = {};
  for (const [name, field] of [['--max-auth-users', 'maxAuthUsers'],
    ['--max-firestore-documents', 'maxFirestoreDocuments']]) {
    if (values.has(name)) {
      const number = Number(values.get(name));
      if (!Number.isSafeInteger(number) || number < 1) throw new Error('Invalid projection limit');
      limits[field] = number;
    }
  }
  if (mode !== 'dry-run' && (values.get('--confirm-target-db') !== 'clrs_staging'
      || !/^[a-f0-9]{64}$/.test(values.get('--confirm-archive-sha256') ?? ''))) {
    throw new Error('Explicit target database and archive hash are required');
  }
  if (['stage', 'rollback'].includes(mode)) {
    if (!values.has('--receipt-file')) throw new Error('Encrypted receipt file is required');
    for (const name of ['--ack-orphan-profiles', '--ack-accounts-without-profile']) {
      if (!/^\d+$/.test(values.get(name) ?? '') || !Number.isSafeInteger(Number(values.get(name)))) {
        throw new Error('Explicit source absence counts are required');
      }
    }
  }
  if (mode === 'rollback' && !/^[a-f0-9]{64}$/.test(values.get('--confirm-rollback-archive-sha256') ?? '')) {
    throw new Error('Explicit rollback archive hash is required');
  }
  return { values, mode, limits };
}

async function privateReceiptOutput(path, inputs) {
  if (!isAbsolute(path) || path.includes('.partial-')) throw new Error('Private absolute receipt path is required');
  const directory = await realpath(dirname(path));
  const root = await realpath(repository);
  const portion = relative(root, directory);
  if (!(portion === '..' || portion.startsWith(`..${sep}`) || isAbsolute(portion))) {
    throw new Error('Projection receipt must stay outside the repository');
  }
  const info = await stat(directory);
  if (!info.isDirectory() || (info.mode & 0o077) !== 0) throw new Error('Receipt directory must be private');
  const output = resolve(directory, path.slice(path.lastIndexOf(sep) + 1));
  if ([inputs.archivePath, inputs.keyPath].includes(output)) throw new Error('Receipt cannot replace archive or key');
  try { await stat(output); } catch (error) {
    if (error.code === 'ENOENT') return output;
    throw error;
  }
  throw new Error('Receipt already exists; verify an uncertain stage outcome before retrying');
}

export async function readProfileProjectionReceipt(path, key) {
  let receipt;
  let completed = false;
  for await (const frame of readEncryptedArchive(await privateInput(path, 'Projection receipt'), key)) {
    if (frame.type !== 'json') throw new Error('Invalid encrypted projection receipt');
    if (frame.record.kind === 'clrs-profile-projection-receipt' && !receipt && !completed) {
      receipt = frame.record;
    } else if (frame.record.kind === 'end' && receipt && !completed
        && frame.record.summary?.receiptRecords === 1) completed = true;
    else throw new Error('Invalid encrypted projection receipt order');
  }
  if (!completed || !receipt) throw new Error('Incomplete encrypted projection receipt');
  return receipt;
}

async function writeReceipt(path, key, receipt) {
  const writer = await EncryptedArchiveWriter.create(path, key);
  try {
    await writer.writeJson(receipt);
    await writer.finish({ receiptRecords: 1 });
    // The archive file itself was synced by finish(). Also persist the new
    // directory entry before COMMIT can make the database changes durable.
    const directory = await open(dirname(path), 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  } catch (error) {
    await writer.abort().catch(() => {});
    throw error;
  }
}

export async function mainProfileProjection(args = process.argv.slice(2)) {
  const { values, mode, limits } = parseProfileProjectionArgs(args);
  const inputs = await loadImportInputs(values, limits);
  let client;
  try {
    const plan = await prepareProfileProjection(inputs);
    if (mode === 'dry-run') return profileProjectionSummary(plan);
    if (values.get('--confirm-archive-sha256') !== plan.archiveSha256) throw new Error('Archive hash confirmation mismatch');
    const confirmations = {
      targetDatabase: values.get('--confirm-target-db'),
      archiveSha256: values.get('--confirm-archive-sha256'),
      orphanProfiles: Number(values.get('--ack-orphan-profiles')),
      accountsWithoutProfile: Number(values.get('--ack-accounts-without-profile')),
      rollbackArchiveSha256: values.get('--confirm-rollback-archive-sha256'),
    };
    let output;
    let receipt;
    if (mode === 'stage') {
      output = await privateReceiptOutput(values.get('--receipt-file'), {
        ...inputs, keyPath: await privateInput(values.get('--key-file'), 'Key'),
      });
    } else if (values.has('--receipt-file')) {
      receipt = await readProfileProjectionReceipt(values.get('--receipt-file'), inputs.key);
    }
    const mysql = await import('mysql2/promise');
    client = await mysql.createConnection(await mysql84Config(values));
    if (mode === 'stage') return await stageProfileProjection(client, plan, confirmations,
      (record) => writeReceipt(output, inputs.key, record));
    if (mode === 'verify') return await verifyProfileProjection(client, plan, confirmations.targetDatabase, receipt);
    return await rollbackProfileProjection(client, plan, confirmations, receipt);
  } finally {
    await client?.end();
    inputs.key.fill(0);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  mainProfileProjection().then((result) => {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  }).catch(() => {
    // mysql2 exceptions may include the rejected row/email. Never print them.
    // A published receipt after a connection loss is an unknown outcome: use
    // verify with that receipt; do not retry stage or delete it automatically.
    process.stderr.write('Profile projection failed. If a receipt exists, verify the uncertain transaction outcome before retrying.\n');
    process.exitCode = 1;
  });
}
