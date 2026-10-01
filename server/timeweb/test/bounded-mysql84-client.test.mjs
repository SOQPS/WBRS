import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import test from 'node:test';
import { createBoundedMysql84Client, MYSQL84_TRANSPORT_TIMEOUTS } from '../bounded-mysql84-client.mjs';

const deferred = () => {
  let resolve; let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const tick = () => new Promise((resolve) => setImmediate(resolve));

class Driver {
  constructor(handler = async () => [[], []]) {
    this.handler = handler; this.calls = []; this.destroyed = 0; this.socketDestroyed = 0;
    this.connection = { stream: { destroy: () => { this.socketDestroyed++; } } };
  }
  query(command, params) {
    this.calls.push({ method: 'query', command, params, argc: arguments.length });
    return this.handler('query', command, params);
  }
  execute(command, params) {
    this.calls.push({ method: 'execute', command, params, argc: arguments.length });
    return this.handler('execute', command, params);
  }
  end() { this.calls.push({ method: 'end' }); return this.handler('end'); }
  destroy() { this.destroyed++; } // Like pinned mysql2, not a hard socket kill.
}

function bounded(driver, ms = 20) {
  return createBoundedMysql84Client(driver, { operationTimeoutMs: ms, closeTimeoutMs: ms });
}

test('normal query/execute preserve SQL, parameter reference, result and exact optional argument shape', async () => {
  const result = [[{ value: 'synthetic' }], [{ name: 'value' }]];
  const driver = new Driver(async () => result); const client = bounded(driver, 500);
  const params = ['Synthetic value', Buffer.from('Synthetic bytes')];
  assert.equal(await client.query('SELECT ?', params), result);
  assert.equal(await client.execute({ sql: 'SELECT ?', rowsAsArray: true, timeout: 999999 }, params), result);
  assert.equal(await client.query('SHOW GRANTS'), result);
  assert.equal(driver.calls[0].params, params); assert.equal(driver.calls[1].params, params);
  assert.deepEqual(driver.calls[0].command, { sql: 'SELECT ?', timeout: 500 });
  assert.deepEqual(driver.calls[1].command, { sql: 'SELECT ?', rowsAsArray: true, timeout: 500 });
  assert.equal(driver.calls[2].argc, 1);
  assert.equal(driver.destroyed, 0);
  await client.end();
});

test('pinned mysql2 command contract accepts timeout for query and binary execute', async () => {
  const require = createRequire(import.meta.url);
  const Query = require('../node_modules/mysql2/lib/commands/query.js');
  const Execute = require('../node_modules/mysql2/lib/commands/execute.js');
  const pkg = JSON.parse(await readFile(new URL('../node_modules/mysql2/package.json', import.meta.url)));
  assert.equal(pkg.version, '3.24.5');
  assert.equal(new Query({ sql: 'SELECT 1', timeout: 37 }, () => {}).timeout, 37);
  assert.equal(new Execute({ sql: 'SELECT ?', values: [1], timeout: 37 }, () => {}).timeout, 37);
});

test('absolute execute deadline includes an ignored driver timer/prepare/queue and hard destroys transport', async () => {
  const pending = deferred(); const driver = new Driver(() => pending.promise); const client = bounded(driver);
  await assert.rejects(client.execute('INSERT INTO synthetic VALUES (?)', ['Synthetic']),
    { code: 'CLRS_MYSQL_OPERATION_TIMEOUT', operation: 'execute', timedOut: true });
  assert.equal(driver.calls.length, 1); assert.equal(driver.calls[0].command.timeout, 20);
  assert.equal(driver.destroyed, 1); assert.equal(driver.socketDestroyed, 1);
  await assert.rejects(client.query('ROLLBACK'), { code: 'CLRS_MYSQL_TRANSPORT_CLOSED' });
  assert.equal(driver.calls.length, 1);
  pending.resolve([{ affectedRows: 1 }]); await tick();
  await assert.rejects(client.execute('SELECT 1'), { code: 'CLRS_MYSQL_TRANSPORT_CLOSED' });
  await client.end();
});

test('driver command timeout closes connection immediately, before the outer deadline', async () => {
  const raw = Object.assign(new Error('Synthetic private SQL/credentials must not escape'),
    { code: 'PROTOCOL_SEQUENCE_TIMEOUT', sql: 'Synthetic private SQL' });
  const driver = new Driver(async () => { throw raw; }); const client = bounded(driver, 500);
  await assert.rejects(client.query('SELECT ?', ['Synthetic secret']), (error) => {
    assert.equal(error.code, 'CLRS_MYSQL_OPERATION_TIMEOUT');
    assert.equal(error.cause, undefined); assert.equal(error.sql, undefined);
    assert.equal(`${error.stack}${JSON.stringify(error)}`.includes('Synthetic private'), false);
    assert.equal(`${error.stack}${JSON.stringify(error)}`.includes('Synthetic secret'), false);
    return true;
  });
  assert.equal(driver.destroyed, 1); assert.equal(driver.socketDestroyed, 1);
});

test('hung ROLLBACK is bounded and cannot be mistaken for confirmed rollback', async () => {
  const driver = new Driver(() => new Promise(() => {})); const client = bounded(driver);
  await assert.rejects(client.query('ROLLBACK'), { code: 'CLRS_MYSQL_OPERATION_TIMEOUT' });
  assert.equal(driver.destroyed, 1); assert.equal(driver.socketDestroyed, 1);
  await client.end(); assert.equal(driver.calls.length, 1);
});

test('lost late COMMIT remains unknown, cannot reuse/retry, and does not adopt late acknowledgement', async () => {
  const pending = deferred(); const driver = new Driver(() => pending.promise); const client = bounded(driver);
  await assert.rejects(client.query('COMMIT'),
    { code: 'CLRS_MYSQL_COMMIT_OUTCOME_UNKNOWN', operation: 'query', commitOutcomeUnknown: true, timedOut: true });
  await assert.rejects(client.query('ROLLBACK'), { code: 'CLRS_MYSQL_TRANSPORT_CLOSED' });
  await assert.rejects(client.query('COMMIT'), { code: 'CLRS_MYSQL_TRANSPORT_CLOSED' });
  assert.equal(driver.calls.length, 1);
  pending.resolve([{ serverActuallyCommitted: true }]); await tick();
  assert.equal(driver.destroyed, 1); assert.equal(driver.socketDestroyed, 1);
  await client.end();
});

test('a rejected COMMIT has a safe unknown error without raw driver SQL or cause', async () => {
  const raw = Object.assign(new Error('Synthetic account/token payload'),
    { code: 'ECONNRESET', sql: 'COMMIT Synthetic private metadata' });
  const driver = new Driver(async () => { throw raw; }); const client = bounded(driver);
  await assert.rejects(client.execute({ sql: ' COMMIT; ' }), (error) => {
    assert.equal(error.commitOutcomeUnknown, true);
    assert.equal(error.code, 'CLRS_MYSQL_COMMIT_OUTCOME_UNKNOWN');
    assert.equal(error.cause, undefined); assert.equal(error.sql, undefined);
    assert.equal(`${error.stack}${JSON.stringify(error)}`.includes('Synthetic'), false);
    return true;
  });
  assert.equal(driver.calls.length, 1); assert.equal(driver.destroyed, 1);
});

test('late driver rejection after outer timeout is consumed; no raw failure is surfaced', async () => {
  const pending = deferred(); const driver = new Driver(() => pending.promise); const client = bounded(driver);
  await assert.rejects(client.query('SELECT ?', ['Synthetic']), { code: 'CLRS_MYSQL_OPERATION_TIMEOUT' });
  pending.reject(Object.assign(new Error('Synthetic secret late failure'), { code: 'ECONNRESET' }));
  await tick(); assert.equal(driver.destroyed, 1);
});

test('one timed out queued operation terminates every pending result, including uncertain COMMIT', async () => {
  const driver = new Driver(() => new Promise(() => {})); const client = bounded(driver);
  const query = client.execute('SELECT 1'); const commit = client.query('COMMIT');
  await Promise.all([
    assert.rejects(query, { code: 'CLRS_MYSQL_OPERATION_TIMEOUT' }),
    assert.rejects(commit, { code: 'CLRS_MYSQL_COMMIT_OUTCOME_UNKNOWN', commitOutcomeUnknown: true }),
  ]);
  assert.equal(driver.destroyed, 1); assert.equal(driver.socketDestroyed, 1);
});

test('graceful close shares a bounded Future and refuses new work while closing', async () => {
  const pending = deferred(); const driver = new Driver(() => pending.promise); const client = bounded(driver);
  const first = client.end(); const second = client.end(); assert.equal(first, second);
  await assert.rejects(client.query('SELECT 1'), { code: 'CLRS_MYSQL_TRANSPORT_CLOSED' });
  await assert.rejects(first, { code: 'CLRS_MYSQL_OPERATION_TIMEOUT', operation: 'end' });
  await assert.rejects(second, { code: 'CLRS_MYSQL_OPERATION_TIMEOUT' });
  assert.equal(driver.calls.length, 1); assert.equal(driver.destroyed, 1); assert.equal(driver.socketDestroyed, 1);
  pending.resolve(); await tick();
  assert.equal(client.end(), first);
});

test('expected nonfatal preflight errno is preserved and does not poison the connection', async () => {
  const denied = Object.assign(new Error('Synthetic denied'), { errno: 1044, code: 'ER_DBACCESS_DENIED_ERROR' });
  let call = 0; const driver = new Driver(async () => { if (!call++) throw denied; return [[], []]; });
  const client = bounded(driver, 500);
  await assert.rejects(client.query('USE default_db'), (error) => error === denied);
  assert.deepEqual(await client.query('SHOW GRANTS'), [[], []]); assert.equal(driver.destroyed, 0);
  await client.end();
});

test('fatal network interruption closes every pending result without leaking driver details', async () => {
  const pending = deferred();
  const raw = Object.assign(new Error('Synthetic private connection context'), { code: 'ECONNRESET', fatal: true });
  const driver = new Driver((method, command) => command.sql === 'SELECT 1'
    ? pending.promise : Promise.reject(raw));
  const client = bounded(driver, 500);
  const first = client.query('SELECT 1'); const second = client.query('SELECT 2');
  for (const call of [first, second]) {
    await assert.rejects(call, (error) => {
      assert.equal(error.code, 'CLRS_MYSQL_TRANSPORT_CLOSED');
      assert.equal(`${error.stack}${JSON.stringify(error)}`.includes('Synthetic private'), false);
      return true;
    });
  }
  pending.resolve([[], []]); await tick();
  assert.equal(driver.destroyed, 1); assert.equal(driver.socketDestroyed, 1);
});

test('invalid wrapper/timeout/input cannot contact the driver', async () => {
  assert.equal(MYSQL84_TRANSPORT_TIMEOUTS.operationTimeoutMs, 30_000);
  assert.equal(MYSQL84_TRANSPORT_TIMEOUTS.closeTimeoutMs, 5_000);
  const driver = new Driver();
  for (const options of [{ operationTimeoutMs: 0 }, { operationTimeoutMs: 60_001 },
    { closeTimeoutMs: Infinity }, { debug: true }]) {
    assert.throws(() => createBoundedMysql84Client(driver, options));
  }
  const client = bounded(driver);
  await assert.rejects(client.execute({ sql: '' })); await assert.rejects(client.query(null));
  assert.equal(driver.calls.length, 0); client.destroy();
  assert.equal(driver.destroyed, 1); assert.equal(driver.socketDestroyed, 1);
});
