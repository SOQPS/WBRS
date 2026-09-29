import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';
import pg from 'pg';

const { Client } = pg;
const CONNECT_TIMEOUT_MS = 2000;
const QUERY_TIMEOUT_MS = 2000;
const PROBE_TIMEOUT_MS = 4500;
const PROBE_CACHE_MS = 3000;

function databaseConfig(env) {
  if (!env.DATABASE_URL) return null;

  const url = new URL(env.DATABASE_URL);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) ||
      !url.hostname || !url.username || !url.password ||
      !url.pathname || url.pathname === '/' || url.hash) {
    throw new Error('Invalid database configuration');
  }

  const sslMode = url.searchParams.get('sslmode');
  if (sslMode && !['require', 'verify-full'].includes(sslMode)) {
    throw new Error('Invalid database TLS configuration');
  }
  if ([...url.searchParams.keys()].some((key) => key !== 'sslmode')) {
    throw new Error('Unsupported database URL option');
  }

  const port = url.port ? Number(url.port) : 5432;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('Invalid database port');
  }

  const ssl = { rejectUnauthorized: true };
  if (env.DATABASE_CA_FILE) {
    ssl.ca = readFileSync(env.DATABASE_CA_FILE, 'utf8');
  }

  return {
    host: url.hostname,
    port,
    user: decodeURIComponent(url.username),
    password: decodeURIComponent(url.password),
    database: decodeURIComponent(url.pathname.slice(1)),
    ssl,
    connectionTimeoutMillis: CONNECT_TIMEOUT_MS,
    query_timeout: QUERY_TIMEOUT_MS,
    statement_timeout: QUERY_TIMEOUT_MS,
    application_name: 'clrs_infra_smoke',
  };
}

export function createDatabaseProbe(env = process.env, ClientType = Client) {
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
      const client = new ClientType(config);
      let timer;
      try {
        const deadline = new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('probe timeout')), PROBE_TIMEOUT_MS);
          timer.unref();
        });
        const check = async () => {
          await client.connect();
          const result = await client.query('SELECT 1');
          return result.rows.length === 1;
        };
        return await Promise.race([check(), deadline]);
      } catch {
        return false;
      } finally {
        clearTimeout(timer);
        client.connection?.stream?.destroy();
        void client.end().catch(() => {});
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
