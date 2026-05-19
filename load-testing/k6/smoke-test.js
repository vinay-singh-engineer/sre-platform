/**
 * Smoke test — validates the service is alive and meeting SLO thresholds
 * at minimal load (1 VU). Run after every deployment.
 *
 * Usage: k6 run --env BASE_URL=http://your-alb-dns load-testing/k6/smoke-test.js
 */
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8000";

const errorRate = new Rate("slo_errors");
const p99Latency = new Trend("slo_p99_latency", true);

export const options = {
  vus: 1,
  duration: "60s",
  thresholds: {
    // SLO: <0.1% error rate
    slo_errors: ["rate<0.001"],
    // SLO: p99 < 500ms
    slo_p99_latency: ["p(99)<500"],
    // Standard HTTP
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<300"],
  },
};

export default function () {
  // Health checks
  const liveness = http.get(`${BASE_URL}/health/live`);
  check(liveness, {
    "liveness 200": (r) => r.status === 200,
    'liveness body has "alive"': (r) => r.json("status") === "alive",
  });

  const readiness = http.get(`${BASE_URL}/health/ready`);
  check(readiness, {
    "readiness 200": (r) => r.status === 200,
    'readiness db ok': (r) => r.json("checks.database") === "ok",
  });

  // App API — list items
  const list = http.get(`${BASE_URL}/api/items`, {
    headers: { "X-Request-ID": `smoke-${__VU}-${__ITER}` },
  });
  const listOk = check(list, {
    "list items 200": (r) => r.status === 200,
    "list items has count": (r) => r.json("count") !== undefined,
  });
  errorRate.add(!listOk);
  p99Latency.add(list.timings.duration);

  // App API — create then retrieve an item
  const payload = JSON.stringify({ name: `smoke-item-${Date.now()}`, description: "smoke test" });
  const created = http.post(`${BASE_URL}/api/items`, payload, {
    headers: { "Content-Type": "application/json", "X-Request-ID": `smoke-create-${__VU}-${__ITER}` },
  });
  const createOk = check(created, {
    "create item 201": (r) => r.status === 201,
    "create item has id": (r) => r.json("id") !== undefined,
  });
  errorRate.add(!createOk);

  if (createOk) {
    const itemId = created.json("id");
    const got = http.get(`${BASE_URL}/api/items/${itemId}`);
    check(got, { "get item 200": (r) => r.status === 200 });

    http.del(`${BASE_URL}/api/items/${itemId}`);
  }

  sleep(1);
}
