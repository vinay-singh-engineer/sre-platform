/**
 * Stress test — pushes the service past its normal operating point to find
 * the breaking point and verify graceful degradation (not hard crashes).
 *
 * IMPORTANT: Run this against a staging environment, NOT production.
 * This will trigger SLO alerts by design.
 *
 * Usage: k6 run --env BASE_URL=http://staging-alb-dns load-testing/k6/stress-test.js
 */
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8000";

const errorRate = new Rate("stress_errors");
const latency = new Trend("stress_latency_ms", true);

export const options = {
  scenarios: {
    stress: {
      executor: "ramping-vus",
      stages: [
        { duration: "2m",  target: 50  },   // ramp
        { duration: "5m",  target: 100 },   // stress
        { duration: "2m",  target: 200 },   // spike
        { duration: "5m",  target: 200 },   // sustain spike — find the wall
        { duration: "2m",  target: 50  },   // recovery check
        { duration: "2m",  target: 0   },   // cooldown
      ],
    },
  },
  // Expectations are relaxed — stress test is about observation, not pass/fail
  thresholds: {
    stress_errors: ["rate<0.50"],           // service shouldn't be > 50% errors even under stress
    http_req_duration: ["p(99)<5000"],      // shouldn't be totally unresponsive
  },
};

export default function () {
  const start = Date.now();

  const r = http.get(`${BASE_URL}/api/items`, {
    timeout: "10s",
    headers: { "X-Request-ID": `stress-${__VU}-${__ITER}` },
  });

  const duration = Date.now() - start;
  latency.add(duration);

  const ok = check(r, {
    "status 200": (r) => r.status === 200,
    "response time < 2s": (r) => r.timings.duration < 2000,
  });
  errorRate.add(!ok);

  // Minimal sleep — maximise pressure
  sleep(0.1);
}

export function handleSummary(data) {
  const errorPct = (data.metrics.stress_errors?.values?.rate || 0) * 100;
  const p99 = data.metrics.stress_latency_ms?.values?.["p(99)"] || 0;
  const peak = data.metrics.vus_max?.values?.max || 0;

  console.log("\n=== STRESS TEST SUMMARY ===");
  console.log(`Peak VUs:       ${peak}`);
  console.log(`Error rate:     ${errorPct.toFixed(2)}%`);
  console.log(`p99 latency:    ${p99.toFixed(0)}ms`);
  console.log(
    `SLO breach:     ${errorPct > 0.1 || p99 > 500 ? "YES — review results" : "No"}`
  );

  return {};
}
