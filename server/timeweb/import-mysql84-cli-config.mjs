import { readFile } from 'node:fs/promises';
import { isIP } from 'node:net';
import { privateInput } from './import-cli-common.mjs';

const DATABASE = 'clrs_staging';

function dnsHost(host) {
  if (typeof host !== 'string' || host.length > 253 || isIP(host)
      || host.includes('..')) return false;
  const labels = host.split('.');
  return labels.length > 1 && labels.every((label) => label.length <= 63
    && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(label));
}

// mysql2 3.24.5 requires verifyIdentity separately from rejectUnauthorized.
// The DNS name is also used as SNI; an IP address cannot pass this guard.
export async function mysql84Config(values, env = process.env) {
  if (values.get('--confirm-target-db') !== DATABASE
      || env.MYSQL_DATABASE !== DATABASE
      || !dnsHost(env.MYSQL_HOST)
      || !/^[1-9]\d{0,4}$/.test(env.MYSQL_PORT ?? '')
      || Number(env.MYSQL_PORT) > 65535
      || typeof env.MYSQL_USER !== 'string' || !env.MYSQL_USER
      || typeof env.MYSQL_PASSWORD !== 'string' || !env.MYSQL_PASSWORD
      || !env.MYSQL_CA_FILE) {
    throw new Error('Invalid MySQL 8.4 target configuration');
  }
  const ca = await readFile(await privateInput(env.MYSQL_CA_FILE, 'MySQL CA'));
  if (!ca.toString('ascii').includes('-----BEGIN CERTIFICATE-----')) {
    throw new Error('Invalid MySQL CA file');
  }
  return {
    host: env.MYSQL_HOST, port: Number(env.MYSQL_PORT),
    user: env.MYSQL_USER, password: env.MYSQL_PASSWORD,
    database: DATABASE, charset: 'utf8mb4', timezone: 'Z',
    ssl: { ca, rejectUnauthorized: true, verifyIdentity: true },
    connectTimeout: 5000, multipleStatements: false,
    supportBigNumbers: true, bigNumberStrings: true,
  };
}
