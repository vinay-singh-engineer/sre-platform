# Runbook: High Error Rate

**Alert:** `SLOErrorBudgetBurnRateCritical` / `SLOErrorBudgetBurnRateHigh`  
**Severity:** Critical / Warning  
**SLO Impact:** Availability — target 99.9%  
**On-call owner:** SRE team

---

## Overview

This runbook guides the responder through diagnosing and resolving an elevated HTTP 5xx error rate on the `sre-platform` service.

**SLO context:**
- Our 30-day error budget is 43.2 minutes of 100% downtime.
- A 14.4× burn rate exhausts the entire monthly budget in ~3 hours.
- A 6× burn rate exhausts it in ~5 days.

---

## Step 1 — Establish incident context (< 5 min)

```bash
# 1a. Confirm the alert is real — check current error rate
curl -s "http://PROMETHEUS_HOST:9090/api/v1/query?query=sum(rate(http_requests_total{status_code=~'5..',job='sre-platform'}[5m]))/sum(rate(http_requests_total{job='sre-platform'}[5m]))" | python3 -m json.tool

# 1b. Check if the service is reachable at all
curl -v http://ALB_DNS/health/ready

# 1c. Check ECS service events for recent deployments or task failures
aws ecs describe-services \
  --cluster sre-platform-prod \
  --services sre-platform-prod \
  --query 'services[0].events[:10]'
```

**Was there a recent deployment?**
- Yes → proceed to [Step 4 — Rollback](#step-4--rollback-if-recent-deployment)
- No → proceed to [Step 2](#step-2--identify-the-error-pattern)

---

## Step 2 — Identify the error pattern (< 10 min)

```bash
# 2a. Break down errors by endpoint
curl -s "http://PROMETHEUS_HOST:9090/api/v1/query?query=sum+by+(endpoint,status_code)(rate(http_requests_total{status_code=~'5..',job='sre-platform'}[5m]))" | python3 -m json.tool

# 2b. Search structured logs for the error pattern
# In Grafana → Explore → Loki:
# {service="sre-platform"} |= "ERROR" | json | line_format "{{.message}} {{.error}}"

# 2c. Check if the DB readiness check is failing
curl -s http://ALB_DNS/health/ready | python3 -m json.tool
```

**Common patterns:**

| Error pattern | Likely cause | Go to |
|:---|:---|:---|
| All endpoints 5xx | App crash / OOM | Step 3a |
| `/health/ready` 503 | DB connection lost | Step 3b |
| Specific endpoint only | Code bug in that path | Step 3c |
| Intermittent, low rate | Memory pressure / throttling | Step 3d |

---

## Step 3 — Remediation paths

### 3a — App crash / OOM: force task replacement
```bash
# Check running task count
aws ecs describe-services \
  --cluster sre-platform-prod \
  --services sre-platform-prod \
  --query 'services[0].{running:runningCount,desired:desiredCount,pending:pendingCount}'

# Force new task deployment (stops stuck tasks)
aws ecs update-service \
  --cluster sre-platform-prod \
  --service sre-platform-prod \
  --force-new-deployment

# Watch until stable
aws ecs wait services-stable \
  --cluster sre-platform-prod \
  --services sre-platform-prod
```

### 3b — DB connection failure: simulate recovery via chaos endpoint
```bash
# If using chaos injection — restore DB
curl -X POST http://ALB_DNS/chaos/db-up

# In a real setup — check RDS connectivity, connection pool exhaustion
# aws rds describe-db-instances --db-instance-identifier sre-platform-db
```

### 3c — Specific endpoint bug: scale down traffic or feature-flag
```bash
# Scale out to dilute failing tasks (buys time)
aws ecs update-service \
  --cluster sre-platform-prod \
  --service sre-platform-prod \
  --desired-count 4

# If a specific endpoint must be disabled, use a WAF rule or ALB fixed-response:
# (this is a manual action — coordinate with eng before doing in prod)
```

### 3d — Memory pressure: scale out
```bash
# Check current CPU/Memory in CloudWatch
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ClusterName,Value=sre-platform-prod Name=ServiceName,Value=sre-platform-prod \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Average
```

---

## Step 4 — Rollback if recent deployment

```bash
# 4a. Identify the previous task definition revision
aws ecs list-task-definitions \
  --family-prefix sre-platform-prod \
  --sort DESC \
  --query 'taskDefinitionArns[:5]'

# 4b. Roll back to the previous revision (replace :N with the revision number)
PREV_TASK_DEF="arn:aws:ecs:us-east-1:ACCOUNT:task-definition/sre-platform-prod:N"

aws ecs update-service \
  --cluster sre-platform-prod \
  --service sre-platform-prod \
  --task-definition "$PREV_TASK_DEF"

aws ecs wait services-stable \
  --cluster sre-platform-prod \
  --services sre-platform-prod
```

---

## Step 5 — Verify resolution

```bash
# Error rate should be below 0.1%
python3 runbooks/scripts/check_health.py --base-url http://ALB_DNS --duration 60

# Confirm error budget burn rate is back to normal
# Grafana: SRE Platform — SLO Dashboard → "Burn Rate (1h window)" should be < 1.0
```

---

## Step 6 — Post-incident

1. Update the incident channel with timeline and resolution.
2. If error budget was consumed significantly → review [error budget policy](../docs/error-budget-policy.md).
3. File a postmortem if:
   - Outage lasted > 5 minutes
   - Error budget burn rate was > 14.4× for > 10 minutes
   - See [postmortem template](../docs/postmortem-template.md)

---

## Automation

```bash
# Run the automated health check script
python3 runbooks/scripts/check_health.py --base-url http://ALB_DNS

# Scale the ECS service
python3 runbooks/scripts/scale_ecs_service.py \
  --cluster sre-platform-prod \
  --service sre-platform-prod \
  --desired-count 4
```
