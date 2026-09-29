#!/usr/bin/env node
import { applicationDefault } from 'firebase-admin/app';
import { createAuthRestAdapter } from './auth-rest.mjs';

const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--project') {
  process.stderr.write('Usage: node check-firebase-auth-access.mjs --project PROJECT_ID\n');
  process.exitCode = 1;
} else {
  try {
    const auth = createAuthRestAdapter({
      credential: applicationDefault(), projectId: args[1],
    });
    // One read-only page request with at most one account. Do not print it.
    await auth.listUsers(1);
    process.stdout.write('Firebase Auth read access confirmed.\n');
  } catch (error) {
    const safe = /^Auth REST read failed \(HTTP [1-5][0-9][0-9]\)$/.test(error.message)
      ? error.message : 'Firebase Auth read access not confirmed';
    process.stderr.write(`${safe}.\n`);
    process.exitCode = 1;
  }
}
