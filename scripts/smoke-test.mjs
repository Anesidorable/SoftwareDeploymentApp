#!/usr/bin/env node
// Post-deployment verification (Project Brief 4.2): readiness, expected version and a database-backed CRUD round trip.
// Usage: node scripts/smoke-test.mjs <base-url> [expected-commit-sha]
// Exits with code 1 on any failure so the pipeline can stop the release or roll back.

const [baseUrl, expectedSha = ''] = process.argv.slice(2);
if (!baseUrl) {
  console.error('Usage: node scripts/smoke-test.mjs <base-url> [expected-commit-sha]');
  process.exit(2);
}

const READY_TIMEOUT_MS = 60_000;
const api = (path) => new URL(path, baseUrl).toString();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function call(method, path, body) {
  const res = await fetch(api(path), {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(5000),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

function check(condition, message) {
  if (!condition) throw new Error(message);
  console.log(`  ✓ ${message}`);
}

async function waitUntilReady() {
  const started = Date.now();
  let last = 'no response';
  while (Date.now() - started < READY_TIMEOUT_MS) {
    try {
      const res = await call('GET', '/api/health');
      const versionOk = !expectedSha || res.body?.version === expectedSha;
      if (res.status === 200 && res.body?.database === 'connected' && versionOk) {
        return { seconds: Math.round((Date.now() - started) / 1000), health: res.body };
      }
      last = `HTTP ${res.status} ${JSON.stringify(res.body)}`;
    } catch (error) {
      last = error.message;
    }
    await sleep(3000);
  }
  throw new Error(`Not ready within ${READY_TIMEOUT_MS / 1000}s (last: ${last})`);
}

console.log(`Smoke test: ${baseUrl}${expectedSha ? ` (expecting ${expectedSha.slice(0, 7)})` : ''}`);
try {
  const ready = await waitUntilReady();
  check(true, `ready in ${ready.seconds}s, database connected, version ${String(ready.health.version).slice(0, 7)}`);

  const page = await fetch(api('/'), { signal: AbortSignal.timeout(5000) });
  check(page.status === 200, 'web page loads (HTTP 200)');

  const name = `pipeline-smoke-${Date.now()}`;
  const created = await call('POST', '/api/list', { name, quantity: 1, category: 'Other' });
  check(created.status === 201 && created.body?.name === name, 'create item (HTTP 201)');
  const id = created.body.id;

  const list = await call('GET', '/api/list');
  check(list.status === 200 && list.body.some((item) => item.id === id), 'read item back from the database');

  const updated = await call('PATCH', `/api/list/${id}`, { purchased: true });
  check(updated.status === 200 && updated.body?.purchased === true, 'mark item as purchased');

  const removed = await call('DELETE', `/api/list/${id}`);
  check(removed.status === 204, 'delete item (HTTP 204)');

  const after = await call('GET', '/api/list');
  check(!after.body.some((item) => item.id === id), 'item is gone after delete');

  console.log('Smoke test passed');
} catch (error) {
  console.error(`  ✗ ${error.message}`);
  console.error('Smoke test FAILED');
  process.exit(1);
}
