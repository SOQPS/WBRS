#!/usr/bin/env node
import { applicationDefault } from 'firebase-admin/app';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateExportPaths } from './export-paths.mjs';
import { privateInput } from './import-cli-common.mjs';
import { EncryptedArchiveWriter } from './encrypted-archive.mjs';
import { createCredentialRestAdapter, exportAuthCredentials,
  verifyAuthCredentialArchive } from './auth-credentials-core.mjs';

export function parseCredentialArgs(args) {
  const values = new Map();
  const allowed = new Set(['--project', '--confirm-project', '--out', '--key-file', '--mode', '--max-users', '--max-pages']);
  for (let index = 0; index < args.length; index += 2) {
    if (!allowed.has(args[index]) || !args[index + 1] || values.has(args[index])) {
      throw new Error('Invalid credential export arguments');
    }
    values.set(args[index], args[index + 1]);
  }
  const project = values.get('--project');
  const mode = values.get('--mode') ?? 'export';
  const maxUsers = Number(values.get('--max-users') ?? '10000');
  const maxPages = Number(values.get('--max-pages') ?? '12');
  if (!/^[a-z][a-z0-9-]{4,62}$/.test(project ?? '') || values.get('--confirm-project') !== project
      || !values.get('--out') || !values.get('--key-file') || !['export', 'verify'].includes(mode)
      || !Number.isSafeInteger(maxUsers) || maxUsers < 1 || maxUsers > 100000
      || !Number.isSafeInteger(maxPages) || maxPages < 1 || maxPages > 100) {
    throw new Error('Credential export target and limits must be confirmed');
  }
  return { values, project, mode, maxUsers, maxPages };
}

export async function main(args = process.argv.slice(2)) {
  const { values, project, mode, maxUsers, maxPages } = parseCredentialArgs(args);
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const { output, keyFile } = await validateExportPaths(repoRoot, values.get('--out'), values.get('--key-file'));
  const key = await readFile(keyFile);
  if (key.length !== 32) throw new Error('Credential archive key must contain 32 bytes');
  if (mode === 'verify') return verifyAuthCredentialArchive({
    archivePath: await privateInput(output, 'Credential archive'), key, project });
  let writer;
  try {
    writer = await EncryptedArchiveWriter.create(output, key);
    const result = await exportAuthCredentials({ writer, project, maxUsers, maxPages,
      api: createCredentialRestAdapter({ credential: applicationDefault(), project }) });
    const verified = await verifyAuthCredentialArchive({ archivePath: output, key, project });
    if (JSON.stringify(result) !== JSON.stringify(verified)) throw new Error('Credential archive readback mismatch');
    return verified;
  } finally { if (writer) await writer.abort(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((summary) => process.stdout.write(`${JSON.stringify(summary)}\n`)).catch(() => {
    process.stderr.write('Encrypted Auth credential operation failed; no standalone login was verified.\n');
    process.exitCode = 1;
  });
}
