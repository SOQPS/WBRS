import { realpath, stat } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';

function isWithin(root, path) {
  const fromRoot = relative(root, path);
  return fromRoot === ''
    || (fromRoot !== '..' && !fromRoot.startsWith(`..${sep}`)
      && !isAbsolute(fromRoot));
}

// Resolve directory symlinks before enforcing the outside-repository rule.
export async function validateExportPaths(repoRoot, outputPath, keyPath) {
  const root = await realpath(repoRoot);
  const requestedOutput = resolve(outputPath);
  const output = join(await realpath(dirname(requestedOutput)), basename(requestedOutput));
  const keyFile = await realpath(keyPath);
  if (isWithin(root, output) || isWithin(root, keyFile)) {
    throw new Error('Key and export must be outside the repository');
  }
  if (output === keyFile) throw new Error('Output cannot overwrite the key');
  const keyStat = await stat(keyFile);
  if (!keyStat.isFile() || (keyStat.mode & 0o077) !== 0) {
    throw new Error('Key must be a private regular file');
  }
  return { output, keyFile };
}
