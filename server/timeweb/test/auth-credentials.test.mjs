import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter, readEncryptedArchive } from '../encrypted-archive.mjs';
import { createCredentialRestAdapter, credentialRecord, exportAuthCredentials,
  validateHashConfig, verifyAuthCredentialArchive } from '../auth-credentials-core.mjs';
import { parseCredentialArgs } from '../export-auth-credentials-encrypted.mjs';

const hashConfig = { algorithm: 'SCRYPT', signerKey: 'c3ludGhldGljLWtleQ==',
  saltSeparator: 'Bw==', rounds: 8, memoryCost: 14 };
const raw = { localId: 'synthetic-user', providerUserInfo: [{ providerId: 'password' }],
  passwordHash: 'c3ludGhldGljLWhhc2g=', salt: 'c3ludGhldGljLXNhbHQ=', version: 2 };
const project = 'clrs-auth-test';

async function paths(t) {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-auth-credential-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return { archivePath: join(directory, 'credential.clrsenc'), key: randomBytes(32) };
}

test('credential extraction retains exact hash, salt, version and UID without assuming login compatibility', () => {
  const result = credentialRecord(raw, 'SCRYPT');
  assert.deepEqual(result.material, {
    passwordHash: raw.passwordHash, passwordSalt: raw.salt, passwordVersion: raw.version,
  });
  assert.equal(result.uid, raw.localId);
  assert.equal(result.materialAvailable, true);
  assert.equal(result.schemeVerified, false);
  assert.equal('email' in result, false);
  assert.equal(credentialRecord({ ...raw, version: '2' }, 'SCRYPT').material.passwordVersion, '2');
});

test('redacted or unavailable password data stays flagged, not converted into a usable credential', () => {
  assert.equal(credentialRecord({ ...raw, passwordHash: 'UkVEQUNURUQ=' }, 'SCRYPT').materialAvailable, false);
  assert.equal(credentialRecord({ ...raw, passwordHash: undefined }, 'SCRYPT').materialAvailable, false);
  assert.throws(() => validateHashConfig({ ...hashConfig, signerKey: 'UkVEQUNURUQ=' }));
  assert.throws(() => validateHashConfig({ ...hashConfig, signerKey: undefined }));
});

test('bounded encrypted export authenticates complete readback; secret material is absent from ciphertext', async (t) => {
  const input = await paths(t);
  const writer = await EncryptedArchiveWriter.create(input.archivePath, input.key);
  const result = await exportAuthCredentials({ project, writer,
    api: { hashConfig: async () => hashConfig, listUsers: async () => ({ users: [raw] }) } });
  const verified = await verifyAuthCredentialArchive({ ...input, project });
  assert.deepEqual(result, verified);
  assert.equal(verified.authUsers, 1);
  assert.equal(verified.materialAvailable, 1);
  assert.equal(verified.standaloneLoginVerified, false);
  const bytes = await readFile(input.archivePath);
  assert.equal(bytes.includes(Buffer.from(raw.passwordHash)), false);
  assert.equal(bytes.includes(Buffer.from(hashConfig.signerKey)), false);
  const records = [];
  for await (const frame of readEncryptedArchive(input.archivePath, input.key)) records.push(frame.record);
  assert.deepEqual(records[1].hashConfig, hashConfig);
});

test('configuration change or duplicate pagination prevents archive publication', async (t) => {
  for (const failure of ['changed-config', 'repeat-token', 'user-limit']) {
    const input = await paths(t);
    let configs = 0;
    const writer = await EncryptedArchiveWriter.create(input.archivePath, input.key);
    try {
      await assert.rejects(exportAuthCredentials({ project, writer, maxUsers: 1, maxPages: 3,
        api: { hashConfig: async () => ({ ...hashConfig,
          rounds: failure === 'changed-config' && configs++ ? 9 : 8 }),
        listUsers: async () => ({ users: failure === 'repeat-token' ? [] : [raw],
          pageToken: failure === 'repeat-token' ? 'repeat' : failure === 'user-limit' ? 'next' : undefined }) } }));
      await assert.rejects(readFile(input.archivePath), { code: 'ENOENT' });
    } finally { await writer.abort(); }
  }
});

test('REST adapter performs only bounded GET and exports configuration without logging it', async () => {
  const calls = [];
  const adapter = createCredentialRestAdapter({ project,
    credential: { getAccessToken: async () => ({ access_token: 'synthetic-access' }) },
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), method: options.method, body: options.body });
      return { ok: true, json: async () => String(url).includes('/config')
        ? { signIn: { hashConfig } } : { users: [raw] } };
    } });
  assert.deepEqual(await adapter.hashConfig(), hashConfig);
  assert.equal((await adapter.listUsers()).users.length, 1);
  assert.equal(calls.every((call) => call.method === 'GET' && call.body === undefined), true);
  assert.match(calls[1].url, /maxResults=1000/);
});

test('CLI requires exact source confirmation and refuses secret values as flags', () => {
  const args = ['--project', project, '--confirm-project', project,
    '--out', '/private/credential.clrsenc', '--key-file', '/private/new.key'];
  assert.equal(parseCredentialArgs(args).mode, 'export');
  assert.throws(() => parseCredentialArgs([...args, '--signer-key', 'forbidden']));
  assert.throws(() => parseCredentialArgs([...args, '--max-pages', '0']));
});
