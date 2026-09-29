import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { loadImportInputs, parseImportArgs, privateMediaConfig } from '../import-cli-common.mjs';
import { mysql84Config } from '../import-mysql84-cli-config.mjs';

const source = {
  kind: 'source', format: 2, project: 'clrs-cli-test', database: '(default)',
  bucket: 'clrs-cli-test.appspot.com', scope: 'all', storagePrefix: '',
  completeSource: true, passwordHashesIncluded: false,
};
const summary = {
  authUsers: 0, authListPages: 0, firestoreDocuments: 0,
  firestoreMissingParents: 0, firestoreReferences: 0,
  firestoreCollections: 0, firestoreListPages: 0,
  storageObjects: 0, storageBytes: 0, storageListPages: 0,
};
const script = fileURLToPath(new URL('../import-clrsx2-mysql84.mjs', import.meta.url));

async function inputs(t) {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-mysql-cli-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const archivePath = join(directory, 'full.clrsenc');
  const keyPath = join(directory, 'archive.key');
  const caPath = join(directory, 'mysql-ca.pem');
  const key = randomBytes(32);
  const writer = await EncryptedArchiveWriter.create(archivePath, key);
  await writer.writeJson(source);
  await writer.finish(summary);
  await writeFile(keyPath, key, { mode: 0o600 });
  await writeFile(caPath, '-----BEGIN CERTIFICATE-----\nSYNTHETIC\n-----END CERTIFICATE-----\n',
    { mode: 0o600 });
  return { archivePath, keyPath, caPath };
}

function sourceArgs({ archivePath, keyPath }) {
  return ['--archive', archivePath, '--key-file', keyPath,
    '--project', source.project, '--database', source.database,
    '--bucket', source.bucket];
}

const s3Env = {
  S3_ENDPOINT: 'https://s3.twcstorage.ru/', S3_REGION: 'ru-1',
  AWS_ACCESS_KEY_ID: 'synthetic-key', AWS_SECRET_ACCESS_KEY: 'synthetic-secret',
  TIMEWEB_API_TOKEN: 'synthetic-token',
};

test('MySQL CLI dry-run validates archive with no target configuration or network', async (t) => {
  const paths = await inputs(t);
  const result = spawnSync(process.execPath, [script, ...sourceArgs(paths),
    '--mode', 'dry-run'], { encoding: 'utf8', env: { PATH: process.env.PATH } });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), {
    mode: 'dry-run', authUsers: 0, firestoreDocuments: 0,
    storageObjects: 0, storageBytes: 0,
  });
  const wrongSourceArgs = sourceArgs(paths);
  wrongSourceArgs[wrongSourceArgs.indexOf('--project') + 1] = 'wrong';
  const mismatch = spawnSync(process.execPath, [script, ...wrongSourceArgs],
    { encoding: 'utf8', env: { PATH: process.env.PATH } });
  assert.equal(mismatch.status, 1);
  assert.match(mismatch.stderr, /CLRSX2 MySQL import failed/);
  assert.equal(mismatch.stderr.includes('clrs-cli-test'), false);
});

test('shared CLI guards reject duplicate options, unsafe limits and nonprivate files', async (t) => {
  const paths = await inputs(t);
  assert.throws(() => parseImportArgs([...sourceArgs(paths), '--mode', 'stage',
    '--mode', 'verify']), /Invalid import arguments/);
  assert.throws(() => parseImportArgs([...sourceArgs(paths),
    '--max-auth-users', '0']), /Invalid import limit/);
  assert.throws(() => parseImportArgs([...sourceArgs(paths), '--unknown', 'x']),
    /Invalid import arguments/);
  const parsed = parseImportArgs(sourceArgs(paths));
  assert.equal((await loadImportInputs(parsed.values, parsed.limits)).key.length, 32);
  await chmod(paths.keyPath, 0o644);
  await assert.rejects(loadImportInputs(parsed.values, parsed.limits), /private regular file/);
});

test('MySQL target requires confirmed clrs_staging and TLS hostname verification', async (t) => {
  const paths = await inputs(t);
  const values = new Map([['--confirm-target-db', 'clrs_staging']]);
  const env = {
    MYSQL_HOST: 'db.example.invalid', MYSQL_PORT: '3306',
    MYSQL_USER: 'importer', MYSQL_PASSWORD: 'synthetic-password',
    MYSQL_DATABASE: 'clrs_staging', MYSQL_CA_FILE: paths.caPath,
  };
  const config = await mysql84Config(values, env);
  assert.equal(config.database, 'clrs_staging');
  assert.equal(config.host, 'db.example.invalid');
  assert.deepEqual({ rejectUnauthorized: config.ssl.rejectUnauthorized,
    verifyIdentity: config.ssl.verifyIdentity },
  { rejectUnauthorized: true, verifyIdentity: true });
  assert.equal(config.multipleStatements, false);
  assert.equal(config.charset, 'utf8mb4');
  await assert.rejects(mysql84Config(new Map([['--confirm-target-db', 'default_db']]), env),
    /configuration/);
  await assert.rejects(mysql84Config(values, { ...env, MYSQL_DATABASE: 'default_db' }),
    /configuration/);
  await assert.rejects(mysql84Config(values, { ...env, MYSQL_HOST: '127.0.0.1' }),
    /configuration/);
  await chmod(paths.caPath, 0o644);
  await assert.rejects(mysql84Config(values, env), /private regular file/);
});

test('S3 target name, bucket ID and private credentials must be confirmed', () => {
  const values = new Map([
    ['--target-media-bucket', 'private-clrs-bucket'],
    ['--confirm-private-bucket', 'private-clrs-bucket'],
    ['--timeweb-bucket-id', '42'],
  ]);
  const config = privateMediaConfig(values, s3Env);
  assert.equal(config.endpoint, 'https://s3.twcstorage.ru/');
  assert.equal(config.timewebBucketId, 42);
  assert.throws(() => privateMediaConfig(new Map([
    ...values, ['--confirm-private-bucket', 'other-bucket'],
  ]), s3Env), /must be confirmed/);
  assert.throws(() => privateMediaConfig(values,
    { ...s3Env, S3_ENDPOINT: 'https://example.invalid/' }), /Invalid private S3/);
  assert.throws(() => privateMediaConfig(values,
    { ...s3Env, TIMEWEB_API_TOKEN: '' }), /Invalid private S3/);
});

test('stage CLI refuses absent target setup before any connection', async (t) => {
  const paths = await inputs(t);
  const result = spawnSync(process.execPath, [script, ...sourceArgs(paths),
    '--mode', 'stage', '--confirm-target-db', 'clrs_staging',
    '--target-media-bucket', 'private-clrs-bucket',
    '--confirm-private-bucket', 'private-clrs-bucket',
    '--timeweb-bucket-id', '42'],
  { encoding: 'utf8', env: { PATH: process.env.PATH } });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /CLRSX2 MySQL import failed/);
  assert.equal(result.stdout, '');
});
