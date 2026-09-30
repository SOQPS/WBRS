#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { privateInput } from './import-cli-common.mjs';
import { scanImportArchive } from './import-core.mjs';
import { fingerprint, validateManifest } from './manifest.mjs';

function differenceCount(expected, actual) {
  let missing = 0;
  let added = 0;
  for (const id of expected) if (!actual.has(id)) missing++;
  for (const id of actual) if (!expected.has(id)) added++;
  return { missing, added };
}

// The importer already authenticates every frame and checks each Storage
// object's SHA-256 and size. Its callback buffers at most one object in RAM;
// no decrypted content is written to disk or included in the result.
export async function verifyExportManifest({ archivePath, archiveKey, manifest,
    hmacKey, scanArchive = scanImportArchive }) {
  validateManifest(manifest);
  if (!Buffer.isBuffer(hmacKey) || hmacKey.length < 32
      || fingerprint(hmacKey, 'manifest-key', 'CLRS manifest v2') !== manifest.hmacKeyId) {
    throw new Error('Manifest HMAC key mismatch');
  }
  const expectedAuth = new Set(manifest.auth.users.map((row) => row.uid));
  const expectedDocs = new Set(manifest.firestore.documents.map((row) => row.path));
  const expectedObjects = new Map(manifest.storage.objects.map((row) => [row.key, row]));
  const actualAuth = new Set();
  const actualDocs = new Set();
  const actualObjects = new Set();
  let storageMetadataChanged = 0;
  const scan = await scanArchive({
    archivePath, key: archiveKey,
    onAuth: ({ uid }) => actualAuth.add(fingerprint(hmacKey, 'uid', uid)),
    onDocument: ({ firebasePath }) => actualDocs.add(
      fingerprint(hmacKey, 'document', firebasePath)),
    onObject: ({ name, size, metadata }) => {
      const id = fingerprint(hmacKey, 'object', name);
      actualObjects.add(id);
      const expected = expectedObjects.get(id);
      const md5 = metadata.md5Hash
        ? fingerprint(hmacKey, 'md5', metadata.md5Hash) : null;
      if (expected && (expected.bytes !== size || expected.checksum !== md5)) {
        storageMetadataChanged++;
      }
    },
  });
  if (fingerprint(hmacKey, 'project', scan.source.project) !== manifest.source.project
      || fingerprint(hmacKey, 'bucket', scan.source.bucket) !== manifest.source.bucket) {
    throw new Error('Archive and manifest describe different Firebase sources');
  }
  const auth = differenceCount(expectedAuth, actualAuth);
  const firestore = differenceCount(expectedDocs, actualDocs);
  const storage = differenceCount(new Set(expectedObjects.keys()), actualObjects);
  const comparison = {
    authMissing: auth.missing, authAdded: auth.added,
    firestoreMissing: firestore.missing, firestoreAdded: firestore.added,
    storageMissing: storage.missing, storageAdded: storage.added,
    storageMetadataChanged,
  };
  return {
    equalToInventory: Object.values(comparison).every((count) => count === 0),
    comparison, counts: scan.counts, archiveSha256: scan.archiveSha256,
  };
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 8 || args.some((value, index) =>
      index % 2 === 0 && !['--archive', '--key-file', '--manifest', '--hmac-key-file'].includes(value))) {
    throw new Error('Usage: --archive FILE --key-file FILE --manifest FILE --hmac-key-file FILE');
  }
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    if (values.has(args[index])) throw new Error('Repeated argument');
    values.set(args[index], args[index + 1]);
  }
  if (values.size !== 4) throw new Error('Missing input');
  const archivePath = await privateInput(values.get('--archive'), 'Archive');
  const archiveKeyPath = await privateInput(values.get('--key-file'), 'Archive key');
  const manifestPath = await privateInput(values.get('--manifest'), 'Manifest');
  const hmacKeyPath = await privateInput(values.get('--hmac-key-file'), 'HMAC key');
  const [archiveKey, hmacKey, manifestBytes] = await Promise.all([
    readFile(archiveKeyPath), readFile(hmacKeyPath), readFile(manifestPath),
  ]);
  if (archiveKey.length !== 32) throw new Error('Invalid archive key');
  const result = await verifyExportManifest({ archivePath, archiveKey,
    manifest: JSON.parse(manifestBytes.toString('utf8')), hmacKey });
  process.stdout.write(`${JSON.stringify({ ...result,
    manifestSha256: createHash('sha256').update(manifestBytes).digest('hex') })}\n`);
  if (!result.equalToInventory) process.exitCode = 2;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => {
    // Raw parsing, SDK and filesystem errors may contain private paths or
    // values. Shared logs receive only a generic failure message.
    process.stderr.write('Encrypted archive verification failed.\n');
    process.exitCode = 1;
  });
}
