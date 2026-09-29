#!/usr/bin/env node
// Read-only, bounded capture. Credentials and plaintext profiles never go to disk.
import { execFileSync, spawnSync } from 'node:child_process';
import { randomBytes, createHash } from 'node:crypto';
import { mkdir, chmod, writeFile, readFile, realpath } from 'node:fs/promises';
import { dirname, resolve, relative, isAbsolute, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EncryptedArchiveWriter, readEncryptedArchive } from '../../server/timeweb/encrypted-archive.mjs';

const project = 'chatapp-4e347';
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const prefix = `projects/${project}/databases/(default)/documents`;
const isWithin = (root, path) => {
  const rel = relative(root, path);
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
};

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 4 || args[0] !== '--confirm-project'
      || args[1] !== project || args[2] !== '--out-dir') {
    throw new Error('Use --confirm-project chatapp-4e347 --out-dir /private/location');
  }
  // The Git checkout also owns the parent AGENTS.md. Resolve symlinks before
  // changing permissions or creating a key anywhere under that checkout.
  const checkout = await realpath(resolve(repo, '..'));
  const requestedOut = resolve(args[3]);
  if (isWithin(checkout, requestedOut)) throw new Error('Output must be outside source tree');
  await mkdir(requestedOut, { recursive: true, mode: 0o700 });
  const out = await realpath(requestedOut);
  if (isWithin(checkout, out)) throw new Error('Output must be outside source tree');
  await chmod(out, 0o700);
  const token = execFileSync('gcloud', ['auth', 'application-default', 'print-access-token'], {
    encoding: 'utf8', timeout: 20_000, maxBuffer: 8192,
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
  if (!token) throw new Error('Credentials unavailable');
  async function request(url, body) {
    const response = await fetch(url, {
      method: body ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(25_000),
    });
    if (!response.ok) throw new Error(`Read failed HTTP ${response.status}`);
    return response.json();
  }
  const countResponse = await request(`https://firestore.googleapis.com/v1/${prefix}:runAggregationQuery`, {
    structuredAggregationQuery: {
      structuredQuery: { from: [{ collectionId: 'users' }] },
      aggregations: [{ alias: 'total', count: {} }],
    },
  });
  const counted = countResponse.find((item) => item.result);
  const expected = Number(counted?.result?.aggregateFields?.total?.integerValue);
  const readTime = counted?.readTime;
  if (!Number.isSafeInteger(expected) || expected < 0 || expected > 10_000
      || typeof readTime !== 'string') throw new Error('Snapshot limit or readTime unavailable');

  const key = randomBytes(32);
  await writeFile(resolve(out, 'profile-review.key'), key, { mode: 0o600, flag: 'wx' });
  const summary = { project, scope: 'users-root-only', readTime, expectedDocuments: expected,
    sourceDocuments: 0, privateEmailDocuments: 0, hiddenProfiles: 0, uidFieldMismatch: 0,
    fieldPresence: {}, writesExecuted: 0, authIncluded: false, subcollectionsIncluded: false,
    storageBytesIncluded: false, productionApproved: false };
  const source = [];
  const seenNames = new Set();
  const seenPages = new Set();
  let pageToken;
  let snapshot;
  let review;
  try {
    snapshot = await EncryptedArchiveWriter.create(resolve(out, 'users-root-snapshot.clrsenc'), key);
    await snapshot.writeJson({ kind: 'metadata', project, scope: summary.scope, readTime });
    for (let page = 0; page < 32; page++) {
      const url = new URL(`https://firestore.googleapis.com/v1/${prefix}/users`);
      url.searchParams.set('pageSize', '500');
      url.searchParams.set('readTime', readTime);
      if (pageToken) url.searchParams.set('pageToken', pageToken);
      const response = await request(url);
      for (const doc of response.documents ?? []) {
        const path = doc.name?.slice(prefix.length + 1);
        if (!doc.name?.startsWith(`${prefix}/users/`) || !/^users\/[^/]+$/.test(path)
            || !doc.updateTime || seenNames.has(doc.name)) throw new Error('Unexpected or duplicate document');
        if (++summary.sourceDocuments > 10_000) throw new Error('Profile limit reached');
        seenNames.add(doc.name);
        source.push(doc);
        const uid = path.slice('users/'.length);
        const fields = doc.fields ?? {};
        if (fields.uid?.stringValue && fields.uid.stringValue !== uid) summary.uidFieldMismatch++;
        for (const field of Object.keys(fields)) summary.fieldPresence[field] = (summary.fieldPresence[field] ?? 0) + 1;
        await snapshot.writeJson({ kind: 'firestore-document', path, fields,
          createTime: doc.createTime, updateTime: doc.updateTime });
      }
      pageToken = response.nextPageToken;
      if (!pageToken) break;
      if (seenPages.has(pageToken)) throw new Error('Repeated page token');
      seenPages.add(pageToken);
    }
    if (pageToken || summary.sourceDocuments !== expected) throw new Error('Incomplete snapshot');
    await snapshot.finish(summary);

    // Reuse the already-tested planner. Its private input/output stay in memory.
    const planner = resolve(repo, 'tool/security/plan_private_profile_migration.py');
    const result = spawnSync('python3', ['-c',
      'import importlib.util,json,sys; s=importlib.util.spec_from_file_location("planner",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); json.dump(m.make_plan(json.load(sys.stdin)["documents"]),sys.stdout,ensure_ascii=False)', planner], {
      input: JSON.stringify({ documents: source }), encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024, timeout: 30_000,
    });
    if (result.status !== 0 || result.error) throw new Error('Offline planner failed');
    const plan = JSON.parse(result.stdout);
    if (plan.sourceDocuments !== expected || plan.productionApproved !== false
        || plan.reviewOnly !== true) throw new Error('Invalid review plan');
    summary.privateEmailDocuments = plan.privateEmailDocuments;
    summary.hiddenProfiles = plan.atomicBatches.filter((item) => item.writes[0]?.delete).length;
    review = await EncryptedArchiveWriter.create(resolve(out, 'profile-privacy-review.clrsenc'), key);
    await review.writeJson({ kind: 'metadata', project, scope: 'profile-privacy-review-only', readTime,
      productionApproved: false });
    for (const item of plan.atomicBatches) await review.writeJson({ kind: 'profile-review', ...item });
    await review.finish(summary);

    // Authenticate the actual archives and compare their decrypted payloads without another API read.
    let captured = 0;
    let reviewed = 0;
    for await (const frame of readEncryptedArchive(resolve(out, 'users-root-snapshot.clrsenc'), key)) {
      if (frame.type !== 'json' || frame.record.kind !== 'firestore-document') continue;
      const original = source[captured++];
      if (frame.record.path !== original.name.slice(prefix.length + 1)
          || JSON.stringify(frame.record.fields) !== JSON.stringify(original.fields ?? {})
          || frame.record.updateTime !== original.updateTime) throw new Error('Snapshot verification failed');
    }
    for await (const frame of readEncryptedArchive(resolve(out, 'profile-privacy-review.clrsenc'), key)) {
      if (frame.type !== 'json' || frame.record.kind !== 'profile-review') continue;
      const expectedItem = plan.atomicBatches[reviewed++];
      if (JSON.stringify(frame.record) !== JSON.stringify({ kind: 'profile-review', ...expectedItem })) {
        throw new Error('Review verification failed');
      }
    }
    if (captured !== expected || reviewed !== expected) throw new Error('Archive count mismatch');
    summary.encryptedRoundTripVerified = true;
    summary.archiveSha256 = {};
    for (const name of ['users-root-snapshot.clrsenc', 'profile-privacy-review.clrsenc']) {
      summary.archiveSha256[name] = createHash('sha256').update(await readFile(resolve(out, name))).digest('hex');
    }
    await writeFile(resolve(out, 'profile-review-summary.json'), JSON.stringify(summary, null, 2) + '\n', {
      mode: 0o600, flag: 'wx',
    });
    process.stdout.write(JSON.stringify(summary, null, 2) + '\n');
  } finally {
    await snapshot?.abort();
    await review?.abort();
  }
}

main().catch(() => {
  // No raw errors: network requests and documents may include private identifiers.
  process.stderr.write('Read-only profile capture failed; no production writes were made.\n');
  process.exitCode = 1;
});
