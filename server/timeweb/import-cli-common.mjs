import { readFile, realpath, stat } from 'node:fs/promises';
import { dirname, isAbsolute, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const positiveOptions = new Map([
  ['--max-auth-users', 'maxAuthUsers'],
  ['--max-firestore-documents', 'maxFirestoreDocuments'],
  ['--max-storage-objects', 'maxStorageObjects'],
  ['--max-storage-bytes', 'maxStorageBytes'],
  ['--max-object-bytes', 'maxObjectBytes'],
]);
const namedOptions = new Set([
  '--archive', '--key-file', '--project', '--database', '--bucket',
  '--mode', '--confirm-target-db', '--target-media-bucket',
  '--confirm-private-bucket', '--timeweb-bucket-id', ...positiveOptions.keys(),
]);

export function parseImportArgs(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index];
    if (!namedOptions.has(name) || !args[index + 1] || values.has(name)) {
      throw new Error('Invalid import arguments');
    }
    values.set(name, args[index + 1]);
  }
  for (const name of ['--archive', '--key-file', '--project', '--database', '--bucket']) {
    if (!values.has(name)) throw new Error('Missing source confirmation');
  }
  const mode = values.get('--mode') ?? 'dry-run';
  if (!['dry-run', 'stage', 'verify'].includes(mode)) throw new Error('Invalid import mode');
  const limits = {};
  for (const [option, field] of positiveOptions) {
    if (values.has(option)) {
      const value = Number(values.get(option));
      if (!Number.isSafeInteger(value) || value < 1) throw new Error('Invalid import limit');
      limits[field] = value;
    }
  }
  return { values, mode, limits };
}

function outside(rootPath, path) {
  const portion = relative(rootPath, path);
  return portion === '..' || portion.startsWith(`..${sep}`) || isAbsolute(portion);
}

export async function privateInput(path, label) {
  const resolved = await realpath(path);
  if (!outside(await realpath(root), resolved) || resolved.includes('.partial-')) {
    throw new Error(`${label} must be a completed private file outside the repository`);
  }
  const info = await stat(resolved);
  if (!info.isFile() || (info.mode & 0o077) !== 0) {
    throw new Error(`${label} must be a private regular file`);
  }
  return resolved;
}

export async function loadImportInputs(values, limits) {
  const archivePath = await privateInput(values.get('--archive'), 'Archive');
  const keyPath = await privateInput(values.get('--key-file'), 'Key');
  if (archivePath === keyPath) throw new Error('Archive and key must be different files');
  const key = await readFile(keyPath);
  if (key.length !== 32) throw new Error('Archive key must be 32 bytes');
  return {
    archivePath, key, limits,
    expectedSource: {
      project: values.get('--project'), database: values.get('--database'),
      bucket: values.get('--bucket'),
    },
  };
}

export function privateMediaConfig(values, env = process.env) {
  const mediaBucket = values.get('--target-media-bucket');
  if (!mediaBucket || !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(mediaBucket)
      || mediaBucket !== values.get('--confirm-private-bucket')) {
    throw new Error('A private target media bucket must be confirmed');
  }
  const endpoint = new URL(env.S3_ENDPOINT ?? '');
  const timewebBucketId = Number(values.get('--timeweb-bucket-id'));
  if (endpoint.toString() !== 'https://s3.twcstorage.ru/'
      || !env.S3_REGION || !env.AWS_ACCESS_KEY_ID || !env.AWS_SECRET_ACCESS_KEY
      || !Number.isSafeInteger(timewebBucketId) || timewebBucketId < 1
      || !env.TIMEWEB_API_TOKEN) {
    throw new Error('Invalid private S3 target configuration');
  }
  return { mediaBucket, endpoint: endpoint.toString(), timewebBucketId,
    region: env.S3_REGION, timewebToken: env.TIMEWEB_API_TOKEN };
}
