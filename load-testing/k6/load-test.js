/**
 * Load test — ramps up to a realistic sustained load to verify the service
 * maintains SLO thresholds under production-like traffic.
 *
 * Usage: k6 run --env BASE_URL=http://your-alb-dns load-testing/k6/load-test.js
 */
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";
import { randomIntBetween } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8000";

const sloErrors = new Rate("slo_errors");
const sloLatency = new Trend("slo_latency_ms", true);
const itemsCreated = new Counter("items_created");

export const options = {
  scenarios: {
    // Ramp up, sustain, ramp down — simulates a realistic traffic pattern
    load: {
      executor: "ramping-vus",
      stages: [
        { duration: "2m", target: 10 },   // warm up
        { duration: "5m", target: 25 },   // ramp to load
        { duration: "10m", target: 25 },  // sustain
        { duration: "2m", target: 0 },    // ramp down
      ],
    },
  },
  thresholds: {
    // SLO: availability — error rate < 0.1%
    slo_errors: ["rate<0.001"],
    // SLO: latency — p99 < 500ms
    slo_latency_ms: ["p(99)<500", "p(95)<200"],
    // General HTTP
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(99)<500"],
  },
};

// Simulates a realistic distribution of user behaviour
const scenarios = [
  { weight: 40, fn: listItems },
  { weight: 30, fn: createAndReadItem },
  { weight: 20, fn: checkHealth },
  { weight: 10, fn: readNonExistentItem },
];

function weightedRandom() {
  const total = scenarios.reduce((s, sc) => s + sc.weight, 0);
  let r = randomIntBetween(1, total);
  for (const sc of scenarios) {
    r -= sc.weight;
    if (r <= 0) return sc.fn;
  }
  return scenarios[0].fn;
}

export default function () {
  const fn = weightedRandom();
  const start = Date.now();
  fn();
  sloLatency.add(Date.now() - start);
  sleep(randomIntBetween(1, 3));
}

function listItems() {
  const r = http.get(`${BASE_URL}/api/items`, {
    headers: { "X-Request-ID": `load-list-${__VU}-${__ITER}` },
  });
  const ok = check(r, {
    "list items 200": (r) => r.status === 200,
    "list latency < 300ms": (r) => r.timings.duration < 300,
  });
  sloErrors.add(!ok);
}

function createAndReadItem() {
  const payload = JSON.stringify({
    name: `load-test-item-${__VU}-${__ITER}`,
    description: "created by k6 load test",
  });
  const created = http.post(`${BASE_URL}/api/items`, payload, {
    headers: {
      "Content-Type": "application/json",
      "X-Request-ID": `load-create-${__VU}-${__ITER}`,
    },
  });
  const ok = check(created, { "create 201": (r) => r.status === 201 });
  sloErrors.add(!ok);

  if (ok) {
    itemsCreated.add(1);
    const id = created.json("id");
    const got = http.get(`${BASE_URL}/api/items/${id}`);
    check(got, { "get created item 200": (r) => r.status === 200 });
    http.del(`${BASE_URL}/api/items/${id}`);
  }
}

function checkHealth() {
  const r = http.get(`${BASE_URL}/health/ready`);
  check(r, { "health ready 200": (r) => r.status === 200 });
  sloErrors.add(r.status !== 200);
}

function readNonExistentItem() {
  const r = http.get(`${BASE_URL}/api/items/nonexistent-id-${__ITER}`);
  check(r, { "not found returns 404": (r) => r.status === 404 });
}
