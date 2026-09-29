#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { compareManifests } from './manifest.mjs';

async function main() {
  const [sourcePath, targetPath, extra] = process.argv.slice(2);
  if (!sourcePath || !targetPath || extra) {
    throw new Error('Usage: node compare-manifests.mjs source.json target.json');
  }
  const source = JSON.parse(await readFile(sourcePath, 'utf8'));
  const target = JSON.parse(await readFile(targetPath, 'utf8'));
  const result = compareManifests(source, target);
  const groups = {};
  for (const item of result.differences) {
    const group = item.split(':')[0];
    groups[group] = (groups[group] ?? 0) + 1;
  }
  process.stdout.write(`${JSON.stringify({ equal: result.equal, differenceCount: result.differences.length, groups })}\n`);
  if (!result.equal) process.exitCode = 2;
}

main().catch(() => {
  process.stderr.write('Manifest comparison failed. Check schema and local file permissions.\n');
  process.exitCode = 1;
});
