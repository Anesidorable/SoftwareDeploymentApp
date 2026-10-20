#!/usr/bin/env node
// Bounded HTTP load test (Project Brief 4.1 "Performance").
// Usage: node scripts/load-test.mjs <base-url> [users=20] [seconds=120] [path=/api/list]
// Example: node scripts/load-test.mjs http://localhost:8080 20 120
// Exits with code 1 if p95 > 300 ms or the error rate is 1% or more, so a pipeline step can use it as a gate.

const [baseUrl, users = '20', seconds = '120', path = '/api/list'] = process.argv.slice(2);
if (!baseUrl) {
  console.error('Usage: node scripts/load-test.mjs <base-url> [users] [seconds] [path]');
  process.exit(2);
}

const url = new URL(path, baseUrl).toString();
const userCount = Number(users);
const endAt = Date.now() + Number(seconds) * 1000;
const P95_TARGET_MS = 300;
const ERROR_RATE_TARGET = 0.01;

const latencies = [];
let errors = 0;

async function virtualUser() {
  while (Date.now() < endAt) {
    const start = performance.now();
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(5000) });
      await res.arrayBuffer();
      if (res.status >= 500) errors++;
    } catch {
      errors++;
    }
    latencies.push(performance.now() - start);
  }
}

console.log(`Load test: ${userCount} users for ${seconds}s against ${url}`);
await Promise.all(Array.from({ length: userCount }, virtualUser));

latencies.sort((a, b) => a - b);
const total = latencies.length;
const pct = (p) => (total ? latencies[Math.min(total - 1, Math.ceil(total * p) - 1)] : 0);
const p95 = pct(0.95);
const errorRate = total ? errors / total : 1;

const result = {
  url,
  users: userCount,
  seconds: Number(seconds),
  requests: total,
  requestsPerSecond: Number((total / Number(seconds)).toFixed(1)),
  p50Ms: Math.round(pct(0.5)),
  p95Ms: Math.round(p95),
  maxMs: Math.round(latencies[total - 1] ?? 0),
  errors,
  errorRatePercent: Number((errorRate * 100).toFixed(2)),
  passed: p95 <= P95_TARGET_MS && errorRate < ERROR_RATE_TARGET,
};
console.log(JSON.stringify(result, null, 2));
process.exit(result.passed ? 0 : 1);
