#!/usr/bin/env node
import { readFile, open } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { scanImportArchive } from './import-core.mjs';
import { privateInput } from './import-cli-common.mjs';
import { validateExportPaths } from './export-paths.mjs';
import { collectManifest, validateManifest } from './manifest.mjs';

// The schema-v2 inventory previously used Admin SDK values, including its
// default Number conversion for int64. Convert only for the comparable HMAC
// manifest. The encrypted archive retains the original typed integer strings.
export function decodeArchiveFields(fields, diagnostics = { unsafeIntegers: 0 }) {
  if (!fields || typeof fields !== 'object' || Array.isArray(fields)) {
    throw new Error('Invalid typed fields');
  }
  const result = {};
  for (const [key, value] of Object.entries(fields)) result[key] = decode(value, diagnostics);
  return result;
}

function decode(value, diagnostics) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).length !== 1) throw new Error('Invalid typed value');
  const [type] = Object.keys(value);
  const raw = value[type];
  switch (type) {
    case 'nullValue':
      if (raw !== null && raw !== 'NULL_VALUE') throw new Error('Invalid null');
      return null;
    case 'booleanValue':
      if (typeof raw !== 'boolean') throw new Error('Invalid boolean');
      return raw;
    case 'stringValue':
      if (typeof raw !== 'string') throw new Error('Invalid string');
      return raw;
    case 'integerValue': {
      if (typeof raw !== 'string' || !/^-?[0-9]+$/.test(raw)) throw new Error('Invalid integer');
      const integer = BigInt(raw);
      if (integer < -(2n ** 63n) || integer >= 2n ** 63n) throw new Error('Invalid int64');
      const number = Number(raw);
      if (!Number.isSafeInteger(number)) diagnostics.unsafeIntegers++;
      return number;
    }
    case 'doubleValue':
      if (typeof raw === 'number') return raw;
      if (!['NaN', 'Infinity', '-Infinity'].includes(raw)) throw new Error('Invalid double');
      return Number(raw);
    case 'timestampValue': {
      if (typeof raw !== 'string') throw new Error('Invalid timestamp');
      const match = /^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z$/.exec(raw);
      const milliseconds = match ? Date.parse(match[1] + 'Z') : NaN;
      if (!Number.isFinite(milliseconds)) throw new Error('Invalid timestamp');
      return { seconds: milliseconds / 1000,
        nanoseconds: Number((match[2] ?? '').padEnd(9, '0')),
        toDate: () => new Date(milliseconds) };
    }
    case 'bytesValue': {
      if (typeof raw !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(raw)) {
        throw new Error('Invalid bytes');
      }
      return Buffer.from(raw, 'base64');
    }
    case 'referenceValue': {
      const match = typeof raw === 'string'
        ? /^projects\/[^/]+\/databases\/[^/]+\/documents\/(.+)$/.exec(raw) : null;
      if (!match || match[1].split('/').length % 2 !== 0) throw new Error('Invalid reference');
      return { path: match[1], firestore: true };
    }
    case 'geoPointValue':
      if (!raw || !Number.isFinite(raw.latitude) || !Number.isFinite(raw.longitude)
          || Math.abs(raw.latitude) > 90 || Math.abs(raw.longitude) > 180) {
        throw new Error('Invalid geopoint');
      }
      return { latitude: raw.latitude, longitude: raw.longitude };
    case 'arrayValue':
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)
          || (raw.values !== undefined && !Array.isArray(raw.values))) throw new Error('Invalid array');
      return (raw.values ?? []).map((item) => decode(item, diagnostics));
    case 'mapValue':
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('Invalid map');
      return decodeArchiveFields(raw.fields ?? {}, diagnostics);
    default: throw new Error('Unsupported typed value');
  }
}

// One local authenticated archive scan. All decoded content remains in memory;
// the returned schema-v2 manifest contains only counts/HMACs and link categories.
export async function collectArchiveManifest({ archivePath, archiveKey, hmacKey,
    scanArchive = scanImportArchive, limits = {
      maxAuthUsers: 10000, maxFirestoreDocuments: 150000,
      maxStorageObjects: 10000, maxStorageBytes: 7200000000,
    } }) {
  const authUsers = [];
  const documents = new Map();
  const collections = new Map();
  const childCollections = new Map();
  const objects = [];
  const diagnostics = { unsafeIntegers: 0 };
  const scanned = await scanArchive({ archivePath, key: archiveKey, limits,
    onAuth: ({ encodedPayload }) => authUsers.push(encodedPayload),
    onDocument: (document) => {
      const path = document.firebasePath;
      documents.set(path, decodeArchiveFields(document.encodedPayload.fields, diagnostics));
      const parts = path.split('/');
      for (let index = 0; index < parts.length; index += 2) {
        const parent = parts.slice(0, index).join('/');
        const collection = parts.slice(0, index + 1).join('/');
        const reference = parts.slice(0, index + 2).join('/');
        if (!collections.has(collection)) collections.set(collection, new Set());
        collections.get(collection).add(reference);
        if (!childCollections.has(parent)) childCollections.set(parent, new Set());
        childCollections.get(parent).add(collection);
      }
    },
    onObject: ({ name, metadata }) => objects.push({ name, metadata }),
  });
  const listCollections = (parent) => [...(childCollections.get(parent) ?? [])].sort().map((path) => ({
    id: path.split('/').at(-1),
    listDocuments: async () => [...collections.get(path)].sort().map((reference) => ({
      path: reference, id: reference.split('/').at(-1),
      get: async () => ({ exists: documents.has(reference), data: () => documents.get(reference) }),
      listCollections: async () => listCollections(reference),
    })),
  }));
  const manifest = await collectManifest({
    auth: { listUsers: async (size, page) => {
      const start = page ? Number(page) : 0;
      const end = Math.min(start + size, authUsers.length);
      return { users: authUsers.slice(start, end), pageToken: end < authUsers.length ? String(end) : undefined };
    } },
    firestore: { listCollections: async () => listCollections('') },
    bucket: { getFiles: async () => [objects, null] },
    projectId: scanned.source.project, bucketName: scanned.source.bucket, key: hmacKey,
    maxAuthUsers: limits.maxAuthUsers, maxAuthListPages: 20,
    maxDocuments: limits.maxFirestoreDocuments, maxObjects: limits.maxStorageObjects,
  });
  validateManifest(manifest);
  return { manifest, counts: scanned.counts, archiveSha256: scanned.archiveSha256, diagnostics };
}

async function main() {
  const args = process.argv.slice(2);
  const names = new Set(['--archive', '--key-file', '--hmac-key-file', '--out']);
  if (args.length !== 8) throw new Error('Invalid arguments');
  const options = new Map();
  for (let index = 0; index < args.length; index += 2) {
    if (!names.has(args[index]) || options.has(args[index]) || !args[index + 1]) {
      throw new Error('Invalid arguments');
    }
    options.set(args[index], args[index + 1]);
  }
  const archivePath = await privateInput(options.get('--archive'), 'Archive');
  const keyPath = await privateInput(options.get('--key-file'), 'Archive key');
  const hmacPath = await privateInput(options.get('--hmac-key-file'), 'HMAC key');
  const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const { output } = await validateExportPaths(repo, options.get('--out'), hmacPath);
  const result = await collectArchiveManifest({ archivePath,
    archiveKey: await readFile(keyPath), hmacKey: await readFile(hmacPath) });
  const file = await open(output, 'wx', 0o600);
  try { await file.writeFile(JSON.stringify(result.manifest, null, 2) + '\n'); }
  finally { await file.close(); }
  process.stdout.write(JSON.stringify({ counts: result.counts,
    archiveSha256: result.archiveSha256, diagnostics: result.diagnostics }) + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => {
    process.stderr.write('Local archive manifest creation failed.\n');
    process.exitCode = 1;
  });
}
