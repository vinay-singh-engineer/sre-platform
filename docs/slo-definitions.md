# SLO Definitions — SRE Platform

This document is the authoritative source for Service Level Indicators (SLIs),
Service Level Objectives (SLOs), and the error budget policy for the `sre-platform` service.

---

## Service Overview

| Property | Value |
|:---|:---|
| Service | `sre-platform` |
| Owner | SRE Team |
| Criticality | Tier 2 |
| Prometheus job | `sre-platform` |
| Dashboard | [SRE Platform — SLO Dashboard](http://grafana:3000/d/sre-slo) |

---

## SLO 1: Availability

### SLI Definition

```
SLI = (good requests) / (valid requests)

Good request:   HTTP response with status code NOT in 5xx
Valid request:  Any HTTP request to the service (excludes /health/* and /metrics)
```

Prometheus expression:
```promql
1 - (
  sum(rate(http_requests_total{status_code=~"5..",job="sre-platform"}[30d]))
  /
  sum(rate(http_requests_total{job="sre-platform"}[30d]))
)
```

### SLO Target

| Window | Target | Error Budget |
|:---|:---|:---|
| 30-day rolling | **99.9%** | 43.2 minutes/month |
| 7-day rolling | 99.5% | 50.4 minutes/week |

### Burn Rate Alert Thresholds

| Alert | Burn Rate | Short Window | Long Window | Severity | Budget Consumed |
|:---|:---|:---|:---|:---|:---|
| `SLOErrorBudgetBurnRateCritical` | 14.4× | 5m | 1h | Critical | 2% in 1h |
| `SLOErrorBudgetBurnRateHigh` | 6× | 1h | 6h | Warning | 5% in 6h |
| `SLOErrorBudgetAlmostExhausted` | — | — | 30d | Warning | >90% consumed |

The **multi-window approach** (from the Google SRE Workbook, Ch. 5) requires BOTH
a short and long window to exceed the threshold before paging. This prevents false
positives from short-lived traffic spikes.

---

## SLO 2: Latency

### SLI Definition

```
SLI = (requests completing in < 500ms) / (valid requests)
```

Prometheus expression (approximated via histogram quantile):
```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{job="sre-platform"}[5m])) by (le)
) < 0.5
```

### SLO Target

| Percentile | Target | Window |
|:---|:---|:---|
| p99 | **< 500ms** | 5-minute rolling |
| p95 | < 200ms | 5-minute rolling |

### Burn Rate Alert Thresholds

| Alert | Condition | Severity |
|:---|:---|:---|
| `SLOLatencyBudgetBurnRateCritical` | p99 > 500ms for 5m (both windows) | Critical |
| `SLOLatencyBudgetBurnRateWarning` | p99 > 250ms for 15m | Warning |

---

## Error Budget Policy

### Principles

1. **Error budget = trust in the system.** When it's full, we can take risks. When it's low, we slow down.
2. **Budget is shared** between SRE and product. Neither team can unilaterally spend it.
3. **Incidents count against budget.** So do risky deployments, migrations, and chaos tests.

### Thresholds and Actions

| Budget Remaining | State | Actions |
|:---|:---|:---|
| > 50% | Green | Normal operations; chaos testing permitted |
| 25–50% | Yellow | Notify team; review release cadence |
| 10–25% | Orange | Freeze non-critical deployments; post-mortems required for all incidents |
| < 10% | Red | **Freeze all deployments.** Only critical security fixes with SRE approval. Incident review board convenes. |
| Exhausted | Black | SLA breach risk. Immediate escalation to VP Engineering. |

### Budget Reset

The error budget resets on a **rolling 30-day basis**, not at month boundaries.
There is no "banking" of unused budget across windows.

---

## Exclusions

The following are **not counted** against the error budget:

- Planned maintenance windows (announced ≥ 24h in advance via status page)
- Force-majeure events (AWS region-level failures, not in our control plane)
- Traffic from internal health probes (`/health/*` endpoints)
- Load test traffic tagged with `X-Load-Test: true` header

---

## Measurement and Reporting

- **Real-time:** Grafana SLO dashboard (updated every 30s)
- **Weekly:** SLO report sent to `#sre-weekly` Slack channel every Monday
- **Monthly:** Error budget review in SRE monthly sync
- **Incident-driven:** Postmortem filed when error budget burn rate > 14.4× for > 10 minutes
