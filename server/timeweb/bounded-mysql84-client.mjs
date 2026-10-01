// Shared migration-only transport. No connection/config/SQL values are logged.
export const MYSQL84_TRANSPORT_TIMEOUTS = Object.freeze({
  operationTimeoutMs: 30_000,
  closeTimeoutMs: 5_000,
});

const networkCodes = new Set(['ETIMEDOUT', 'ECONNRESET', 'ECONNREFUSED', 'EPIPE',
  'PROTOCOL_CONNECTION_LOST', 'PROTOCOL_ENQUEUE_AFTER_FATAL_ERROR']);

function safeError(method, reason, commit) {
  const error = new Error(commit
    ? 'MySQL COMMIT outcome unknown; verify the existing target using a fresh connection before retry'
    : reason === 'timeout'
      ? 'MySQL operation deadline exceeded; a fresh connection is required'
      : 'MySQL transport is closed; a fresh connection is required');
  error.code = commit ? 'CLRS_MYSQL_COMMIT_OUTCOME_UNKNOWN'
    : reason === 'timeout' ? 'CLRS_MYSQL_OPERATION_TIMEOUT' : 'CLRS_MYSQL_TRANSPORT_CLOSED';
  error.operation = method;
  error.timedOut = reason === 'timeout';
  if (commit) error.commitOutcomeUnknown = true;
  return error;
}

function timeout(value) {
  if (!Number.isSafeInteger(value) || value < 1 || value > 60_000) {
    throw new Error('Invalid bounded MySQL transport deadline');
  }
  return value;
}

// mysql2's command timer starts after queuing (execute also first prepares).
// The outer timer includes queue/prepare/result transfer and kills the socket.
export function createBoundedMysql84Client(client, options = {}) {
  if (!client || ['query', 'execute', 'end', 'destroy'].some((method) => typeof client[method] !== 'function')) {
    throw new Error('A mysql2 promise connection is required');
  }
  if (Object.keys(options).some((key) => !['operationTimeoutMs', 'closeTimeoutMs'].includes(key))) {
    throw new Error('Invalid bounded MySQL transport options');
  }
  const operationTimeoutMs = timeout(options.operationTimeoutMs ?? MYSQL84_TRANSPORT_TIMEOUTS.operationTimeoutMs);
  const closeTimeoutMs = timeout(options.closeTimeoutMs ?? MYSQL84_TRANSPORT_TIMEOUTS.closeTimeoutMs);
  const pending = new Set();
  let terminated = false; let closing = false; let closeFlight;

  function destroy(reason = 'closed') {
    if (terminated) return;
    terminated = true;
    for (const abort of [...pending]) abort(reason);
    // In pinned mysql2 3.24.5 PromiseConnection.destroy delegates to
    // BaseConnection.close, which only stream.end()s. Explicitly destroy the
    // actual stream too: a peer that never finishes its socket cannot linger.
    const stream = client.connection?.stream;
    try { client.destroy(); } catch { /* already closed; never expose driver data */ }
    try { stream?.destroy(); } catch { /* teardown failure cannot retry a write */ }
  }

  function bounded(method, invoke, deadlineMs, commit = false) {
    return new Promise((resolve, reject) => {
      let settled = false; let timer;
      function finish(success, value) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        pending.delete(abort);
        if (success) resolve(value); else reject(value);
      }
      const abort = (reason) => finish(false, safeError(method, reason, commit));
      pending.add(abort);
      timer = setTimeout(() => destroy('timeout'), deadlineMs);
      function rejected(error) {
        if (settled) return;
        if (error?.code === 'PROTOCOL_SEQUENCE_TIMEOUT') destroy('timeout');
        else if (commit || method === 'end' || error?.fatal === true || networkCodes.has(error?.code)) destroy('closed');
        else finish(false, error); // Preserve errno/code for exact preflight checks.
      }
      try {
        Promise.resolve(invoke()).then((value) => finish(true, value), rejected);
      } catch (error) { rejected(error); }
    });
  }

  function dispatch(method, input, params, hasParams) {
    if (terminated || closing) return Promise.reject(safeError(method, 'closed', false));
    const sql = typeof input === 'string' ? input : input?.sql;
    if (typeof sql !== 'string' || !sql.trim()
        || (typeof input !== 'string' && (input === null || Array.isArray(input) || typeof input !== 'object'))) {
      return Promise.reject(new Error('Invalid bounded MySQL operation'));
    }
    // Keep SQL/parameter bytes and driver result references unchanged. Caller
    // supplied timeout cannot disable or extend the reviewed transport limit.
    const command = typeof input === 'string' ? { sql, timeout: operationTimeoutMs }
      : { ...input, timeout: operationTimeoutMs };
    const commit = /^COMMIT\s*;?$/i.test(sql.trim());
    return bounded(method, () => hasParams ? client[method](command, params) : client[method](command), operationTimeoutMs, commit);
  }

  return Object.freeze({
    query(input, params) { return dispatch('query', input, params, arguments.length > 1); },
    execute(input, params) { return dispatch('execute', input, params, arguments.length > 1); },
    end() {
      if (closeFlight) return closeFlight;
      if (terminated) return closeFlight = Promise.resolve();
      closing = true;
      closeFlight = bounded('end', () => client.end(), closeTimeoutMs).then((result) => {
        terminated = true;
        return result;
      });
      return closeFlight;
    },
    destroy() { destroy(); },
  });
}
