import assert from 'node:assert/strict';
import { once } from 'node:events';
import { afterEach, test } from 'node:test';
import { createApp, createDatabaseProbe } from '../server.mjs';

const servers = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise((resolve) => {
    server.close(resolve);
  })));
});

async function request(server, path, options) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  servers.push(server);
  const { port } = server.address();
  return fetch(`http://127.0.0.1:${port}${path}`, options);
}

test('only liveness and readiness are exposed', async () => {
  const health = await request(createApp({ checkDatabase: async () => false }), '/healthz');
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), {
    status: 'alive',
    service: 'clrs-infra-smoke',
  });

  const hidden = await request(createApp({ checkDatabase: async () => true }), '/users');
  assert.equal(hidden.status, 404);
  assert.deepEqual(await hidden.json(), { status: 'not_found' });

  const method = await request(
    createApp({ checkDatabase: async () => true }),
    '/readyz',
    { method: 'POST' },
  );
  assert.equal(method.status, 405);
  assert.equal(method.headers.get('allow'), 'GET');
});

test('readiness fails closed without a database and on probe failure', async () => {
  const absent = await request(
    createApp({ checkDatabase: createDatabaseProbe({}) }),
    '/readyz',
  );
  assert.equal(absent.status, 503);
  assert.deepEqual(await absent.json(), { status: 'not_ready' });

  const failed = await request(
    createApp({ checkDatabase: async () => { throw new Error('sensitive detail'); } }),
    '/readyz',
  );
  assert.equal(failed.status, 503);
  assert.equal((await failed.text()).includes('sensitive detail'), false);
});

test('readiness checks only SELECT 1 over verified TLS', async () => {
  let config;
  let query;
  class FakeClient {
    constructor(value) { config = value; }
    async connect() {}
    async query(value) { query = value; return { rows: [{ '?column?': 1 }] }; }
    async end() {}
  }
  const probe = createDatabaseProbe(
    { DATABASE_URL: 'postgres://tester:example@db.example.test:5432/clrs?sslmode=require' },
    FakeClient,
  );
  assert.equal(await probe(), true);
  assert.equal(query, 'SELECT 1');
  assert.equal(config.ssl.rejectUnauthorized, true);
  assert.equal(config.database, 'clrs');
  assert.equal(config.connectionTimeoutMillis <= 2000, true);
  assert.equal(config.query_timeout <= 2000, true);
});

test('an unsafe TLS mode never attempts a connection', async () => {
  class ForbiddenClient {
    constructor() { throw new Error('connection should not be attempted'); }
  }
  const probe = createDatabaseProbe(
    { DATABASE_URL: 'postgres://tester:example@db.example.test/clrs?sslmode=disable' },
    ForbiddenClient,
  );
  assert.equal(await probe(), false);
});
