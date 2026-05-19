# SRE Platform

A production-grade Site Reliability Engineering reference implementation on AWS.
Demonstrates the full SRE lifecycle: instrumenting a service, defining SLOs,
observing error budget burn rates, alerting, automated runbooks, load testing,
and chaos engineering.

> **Interview-ready** — every component maps to a real SRE practice you'll be
> asked about. Built to be deployed, not just read.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          GitHub Actions                         │
│  ┌────────────┐   ┌──────────────────────────────────────────┐  │
│  │  CI (test  │   │  CD (build → ECR push → ECS deploy →     │  │
│  │  lint scan)│   │       smoke test → notify)               │  │
│  └────────────┘   └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────── AWS us-east-1 ────────────────────────────┐
│                                                                  │
│  ┌──────────────────── VPC 10.0.0.0/16 ────────────────────────┐ │
│  │                                                             │ │
│  │  Public Subnets          Private Subnets                    │ │
│  │  ┌──────────┐           ┌──────────────────────────────┐    │ │
│  │  │   ALB    │──────────▶│  ECS Fargate (2–10 tasks)    │    │ │
│  │  │  (HTTP)  │           │  Flask + Gunicorn :8000      │    │ │
│  │  └──────────┘           │  /health/live  /health/ready │    │ │
│  │       ▲                 │  /metrics      /api/items    │    │ │
│  │       │                 └──────────────────────────────┘    │ │
│  │  ┌────┴─────┐                      │                        │ │
│  │  │Monitoring│◀─── scrape /metrics ─┘                        │ │
│  │  │  EC2     │                                               │ │
│  │  │          │  ┌─────────────┐  ┌───────────────────────┐   │ │
│  │  │Prometheus│  │ Alertmanager│  │  Grafana :3000        │   │ │
│  │  │:9090     │─▶│  :9093      │  │  SLO Dashboard        │   │ │
│  │  │          │  │ Slack/PD    │  │  RED metrics dashboard│   │ │
│  │  │Loki:3100 │  └─────────────┘  └───────────────────────┘   │ │
│  │  └──────────┘                                               │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### Key SRE Components

| Component | Technology | What it demonstrates |
|---|---|---|
| Flask app | Python + Gunicorn | RED instrumentation, structured logs, health probes |
| Container | Docker / ECR | Immutable image, healthcheck, non-root user |
| Infra | Terraform modules | Modular IaC, ECS Fargate, ALB, auto-scaling |
| CI/CD | GitHub Actions | OIDC auth, test matrix, SAST, smoke-test gate |
| Metrics | Prometheus | SLI recording rules, multi-window burn rate rules |
| Dashboards | Grafana | SLO dashboard with error budget gauge, RED panels |
| Alerting | Alertmanager | Multi-severity routing, Slack + PagerDuty |
| Logs | Loki + Promtail | Structured JSON log aggregation, log correlation |
| Load testing | k6 | Smoke / load / stress scripts with SLO thresholds |
| Runbooks | Markdown + Python | Documented + automated incident response |
| Chaos | Endpoint injection | Error rate, latency, DB failure scenarios |
| SLOs | Google SRE Workbook | Multi-window burn rate alerting, error budget policy |

---

## Quick Start — Local

```bash
git clone https://github.com/your-org/sre-platform.git
cd sre-platform

# Start the full stack (app + Prometheus + Grafana + Loki)
docker compose up --build

# App:          http://localhost:8000
# Grafana:      http://localhost:3000  (admin / admin)
# Prometheus:   http://localhost:9090
# Alertmanager: http://localhost:9093
```

### Try it out

```bash
# Create an item
curl -X POST http://localhost:8000/api/items \
  -H "Content-Type: application/json" \
  -d '{"name": "my item", "description": "hello SRE"}'

# List items
curl http://localhost:8000/api/items

# Check health
curl http://localhost:8000/health/ready

# View Prometheus metrics
curl http://localhost:8000/metrics
```

### Run tests

```bash
cd app
pip install -r requirements.txt pytest pytest-cov
pytest tests/ -v --cov=app --cov-report=term-missing
```

---

## Chaos Engineering

The app exposes chaos endpoints to simulate real failure modes. Use them to:

- Verify your alerts fire correctly
- Practice incident response against the runbooks
- Validate that auto-scaling and circuit-breaker logic kicks in

```bash
# Inject 20% random 500 errors → triggers SLOErrorBudgetBurnRateCritical
curl -X POST http://localhost:8000/chaos/error-rate/0.2

# Add 300ms artificial latency → triggers SLOLatencyBudgetBurnRateCritical
curl -X POST http://localhost:8000/chaos/latency/300

# Simulate DB failure → /health/ready returns 503
curl -X POST http://localhost:8000/chaos/db-down

# Reset everything
curl -X POST http://localhost:8000/chaos/reset
```

Watch the Grafana SLO dashboard update in real time as chaos is injected.

---

## Load Testing

Requires [k6](https://k6.io/docs/get-started/installation/).

```bash
# Smoke test — run after every deployment
k6 run --env BASE_URL=http://localhost:8000 load-testing/k6/smoke-test.js

# Load test — ramp to 25 VUs over 19 minutes
k6 run --env BASE_URL=http://localhost:8000 load-testing/k6/load-test.js

# Stress test — push to 200 VUs (use staging only!)
k6 run --env BASE_URL=http://STAGING_URL load-testing/k6/stress-test.js
```

Each test enforces SLO thresholds as k6 pass/fail criteria.

---

## Deploy to AWS

### Prerequisites

- AWS account with appropriate permissions
- Terraform ≥ 1.7
- AWS CLI configured
- Docker (for building the image)

### 1. Configure the backend

```bash
# Create an S3 bucket for Terraform state
aws s3 mb s3://your-tf-state-bucket --region us-east-1
aws s3api put-bucket-versioning \
  --bucket your-tf-state-bucket \
  --versioning-configuration Status=Enabled
```

Update `terraform/environments/prod/main.tf` backend block with your bucket name.

### 2. Set variables

```bash
cd terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 3. Deploy infrastructure

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Terraform outputs the ALB URL, ECR repository URL, and Grafana URL.

### 4. Build and push the initial image

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $(terraform output -raw ecr_repository_url | cut -d/ -f1)

# Build and push
docker build -t $(terraform output -raw ecr_repository_url):latest ./app
docker push $(terraform output -raw ecr_repository_url):latest

# Force ECS to use the new image
aws ecs update-service \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --service $(terraform output -raw ecs_service_name) \
  --force-new-deployment
```

### 5. Configure GitHub Actions

Add these secrets to your GitHub repository:

| Secret | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | ARN of IAM role with ECS deploy permissions |

The CI/CD uses OIDC — no long-lived AWS credentials stored in GitHub.

---

## SLO Definitions

See [docs/slo-definitions.md](docs/slo-definitions.md) for the full specification.

**Summary:**
- **Availability SLO:** 99.9% over 30 days (43.2 min error budget)
- **Latency SLO:** p99 < 500ms
- Burn rate alerts fire when budget is consumed at 14.4× (critical) or 6× (warning)

---

## Observability Stack

### Prometheus

- Scrapes `/metrics` every 10s
- Pre-computes SLI recording rules (5m, 1h, 6h, 24h, 30d windows)
- Multi-window burn rate alert rules

### Grafana (`:3000`, admin/admin locally)

| Dashboard | Description |
|---|---|
| SRE Platform — SLO Dashboard | Error budget gauge, burn rate, p99 latency, RED metrics |

### Alertmanager (`:9093`)

Routes alerts by severity:
- **Critical** → PagerDuty (page on-call) + Slack `#sre-incidents`
- **Warning** → Slack `#sre-alerts`

Configure `SLACK_WEBHOOK_URL` and `PAGERDUTY_INTEGRATION_KEY` env vars.

### Loki (`:3100`)

Collects structured JSON logs from all containers. Query in Grafana Explore:
```logql
{service="sre-platform"} | json | level = "ERROR"
```

---

## Project Structure

```
sre-platform/
├── app/                        # Flask microservice
│   ├── app.py                  # App with SRE instrumentation
│   ├── Dockerfile
│   ├── requirements.txt
│   └── tests/test_app.py
├── terraform/
│   ├── modules/
│   │   ├── networking/         # VPC, subnets, NAT gateways
│   │   ├── ecs/                # ECS Fargate, ALB, auto-scaling, ECR
│   │   ├── monitoring/         # Monitoring EC2, security groups
│   │   └── iam/                # ECS task & execution roles
│   └── environments/prod/      # Root module for production
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── alerts/
│   │       ├── slo_alerts.yml  # Multi-window burn rate alerting
│   │       └── infra_alerts.yml
│   ├── grafana/
│   │   ├── dashboards/slo_dashboard.json
│   │   └── provisioning/       # Auto-provisioned datasources/dashboards
│   ├── alertmanager/
│   │   └── alertmanager.yml    # Slack + PagerDuty routing
│   └── loki/
│       ├── loki-config.yml
│       └── promtail-config.yml
├── .github/workflows/
│   ├── ci.yml                  # Test, lint, SAST, Terraform validate
│   └── deploy.yml              # Build → ECR → ECS → smoke test
├── load-testing/k6/
│   ├── smoke-test.js           # Post-deploy validation (SLO assertions)
│   ├── load-test.js            # Realistic traffic (25 VUs, 19min)
│   └── stress-test.js          # Find the breaking point (200 VUs)
├── runbooks/
│   ├── high-error-rate.md      # Step-by-step incident response
│   └── scripts/
│       ├── check_health.py     # Automated health polling
│       └── scale_ecs_service.py
├── docs/
│   ├── slo-definitions.md      # SLIs, SLOs, error budget policy
│   └── postmortem-template.md  # Blameless postmortem template
└── docker-compose.yml          # Full local dev stack
```

---

## Key Design Decisions

**Why multi-window burn rate alerts?**
Single-window alerts (e.g., "error rate > 1% for 5m") generate too many false positives.
The multi-window approach from the Google SRE Workbook requires both a short and long window
to exceed the threshold, filtering out brief spikes that self-resolve.

**Why chaos endpoints in the app?**
Instead of external fault injection tools, the app exposes `POST /chaos/*` endpoints to simulate
failures deterministically. This makes it trivial to test the observability stack without infrastructure
changes. In production, these would be behind an auth gate or removed entirely.

**Why self-hosted Prometheus/Grafana over AWS CloudWatch?**
CloudWatch is fine for AWS-native metrics, but Prometheus + Grafana gives you portable,
vendor-agnostic SLO dashboards with PromQL's expressiveness. This is the stack most SRE
teams run — learning it transfers directly.

---

## References

- [Google SRE Book](https://sre.google/sre-book/) — Chapter 4 (SLOs), Chapter 13 (emergency response)
- [Google SRE Workbook](https://sre.google/workbook/alerting-on-slos/) — Multi-window burn rate alerting
- [Prometheus docs](https://prometheus.io/docs/) — Recording rules, alerting rules
- [k6 docs](https://k6.io/docs/) — Load testing with SLO thresholds
- [Grafana docs](https://grafana.com/docs/) — Dashboard provisioning

---

## License

MIT — use freely, attribute appreciated.
