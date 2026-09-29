import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { isIP } from 'node:net';
import { pathToFileURL } from 'node:url';
import pg from 'pg';

const { Client } = pg;
const CONNECT_TIMEOUT_MS = 2000;
const QUERY_TIMEOUT_MS = 2000;
const PROBE_TIMEOUT_MS = 4500;
const PROBE_CACHE_MS = 3000;

async function createMySQLConnection(config) {
  const mysql = await import('mysql2/promise');
  return mysql.createConnection(config);
}

function databaseConfig(env) {
  if (!env.DATABASE_URL) return null;

  const url = new URL(env.DATABASE_URL);
  const isMySQL = url.protocol === 'mysql:';
  if (!['postgres:', 'postgresql:', 'mysql:'].includes(url.protocol) ||
      !url.hostname || !url.username || !url.password ||
      !url.pathname || url.pathname === '/' || url.hash) {
    throw new Error('Invalid database configuration');
  }

  const database = decodeURIComponent(url.pathname.slice(1));
  if (!database || database.includes('/') ||
      (isMySQL && database !== 'clrs_staging')) {
    throw new Error('Invalid database name');
  }
  if (isMySQL && isIP(url.hostname.replace(/^\[|\]$/g, ''))) {
    throw new Error('Invalid database host');
  }

  const sslMode = url.searchParams.get('sslmode');
  if (url.searchParams.getAll('sslmode').length > 1 ||
      (isMySQL ? (sslMode && sslMode !== 'verify-full') :
        (sslMode && !['require', 'verify-full'].includes(sslMode)))) {
    throw new Error('Invalid database TLS configuration');
  }
  if ([...url.searchParams.keys()].some((key) => key !== 'sslmode')) {
    throw new Error('Unsupported database URL option');
  }

  const port = url.port ? Number(url.port) : (isMySQL ? 3306 : 5432);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('Invalid database port');
  }

  const ssl = { rejectUnauthorized: true };
  // mysql2 does not check the hostname unless verifyIdentity is set explicitly.
  if (isMySQL) ssl.verifyIdentity = true;
  if (env.DATABASE_CA_FILE) {
    ssl.ca = readFileSync(env.DATABASE_CA_FILE, 'utf8');
    if (!ssl.ca.trim()) throw new Error('Invalid database CA');
  }
  if (isMySQL && !ssl.ca) throw new Error('Missing database CA');

  const options = {
    host: url.hostname,
    port,
    user: decodeURIComponent(url.username),
    password: decodeURIComponent(url.password),
    database,
    ssl,
  };
  if (isMySQL) {
    options.connectTimeout = CONNECT_TIMEOUT_MS;
  } else {
    options.connectionTimeoutMillis = CONNECT_TIMEOUT_MS;
    options.query_timeout = QUERY_TIMEOUT_MS;
    options.statement_timeout = QUERY_TIMEOUT_MS;
    options.application_name = 'clrs_infra_smoke';
  }
  return { engine: isMySQL ? 'mysql' : 'postgres', options };
}

export function createDatabaseProbe(
  env = process.env,
  ClientType = Client,
  connectMySQL = createMySQLConnection,
) {
  let config;
  try {
    config = databaseConfig(env);
  } catch {
    return async () => false;
  }
  if (!config) return async () => false;

  let lastResult;
  let expiresAt = 0;
  let inflight;

  return async () => {
    if (Date.now() < expiresAt) return lastResult;
    if (inflight) return inflight;

    inflight = (async () => {
      let client;
      let connecting;
      let timer;
      try {
        const deadline = new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('probe timeout')), PROBE_TIMEOUT_MS);
          timer.unref();
        });
        const check = async () => {
          if (config.engine === 'mysql') {
            connecting = Promise.resolve().then(() => connectMySQL(config.options));
            client = await connecting;
            const [rows] = await client.query({ sql: 'SELECT 1', timeout: QUERY_TIMEOUT_MS });
            return Array.isArray(rows) && rows.length === 1;
          }
          client = new ClientType(config.options);
          await client.connect();
          const result = await client.query('SELECT 1');
          return result.rows.length === 1;
        };
        return await Promise.race([check(), deadline]);
      } catch {
        return false;
      } finally {
        clearTimeout(timer);
        if (config.engine === 'mysql') {
          if (client) client.destroy();
          else void connecting?.then((lateClient) => lateClient.destroy()).catch(() => {});
        } else if (client) {
          client.connection?.stream?.destroy();
          void client.end().catch(() => {});
        }
      }
    })();

    try {
      lastResult = await inflight;
      expiresAt = Date.now() + PROBE_CACHE_MS;
      return lastResult;
    } finally {
      inflight = undefined;
    }
  };
}

function reply(response, status, body, extraHeaders = {}) {
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...extraHeaders,
  });
  response.end(JSON.stringify(body));
}

export function createApp({ checkDatabase = createDatabaseProbe() } = {}) {
  const server = createServer(async (request, response) => {
    // This image deliberately has no CLRS user, admin or SQL routes.
    if (request.url !== '/healthz' && request.url !== '/readyz') {
      reply(response, 404, { status: 'not_found' });
      return;
    }
    if (request.method !== 'GET') {
      reply(response, 405, { status: 'method_not_allowed' }, { allow: 'GET' });
      return;
    }
    if (request.url === '/healthz') {
      reply(response, 200, { status: 'alive', service: 'clrs-infra-smoke' });
      return;
    }

    let ready = false;
    try {
      ready = await checkDatabase();
    } catch {
      // Never include database errors, credentials or connection strings in responses.
    }
    reply(response, ready ? 200 : 503, { status: ready ? 'ready' : 'not_ready' });
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  server.keepAliveTimeout = 1000;
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.PORT ?? 8080);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    process.stderr.write('Invalid port configuration\n');
    process.exitCode = 1;
  } else {
    const server = createApp();
    server.listen(port, '0.0.0.0');
    for (const signal of ['SIGTERM', 'SIGINT']) {
      process.once(signal, () => server.close());
    }
  }
}
