# SRE Platform 🚀

A production-grade Site Reliability Engineering reference implementation on AWS.
Demonstrates the full SRE lifecycle: instrumenting a service, defining SLOs,
observing error budget burn rates, alerting, automated runbooks, and chaos engineering.

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
│  │  │   ALB    │──────────▶│  EKS (2–10 pods)             │    │ │
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
|:---|:---|:---|
| Flask app | Python + Gunicorn | RED instrumentation, structured logs, health probes |
| Container | Docker / ECR | Immutable image, healthcheck, non-root user |
| Infra | Terraform modules | Modular IaC, EKS cluster, managed node group, ECR |
| CI/CD | GitHub Actions | OIDC auth, test matrix, SAST, smoke-test gate |
| Metrics | Prometheus | SLI recording rules, multi-window burn rate rules |
| Dashboards | Grafana | SLO dashboard with error budget gauge, RED panels |
| Alerting | Alertmanager | Multi-severity routing, Slack + PagerDuty |
| Logs | Loki + Promtail | Structured JSON log aggregation, log correlation |
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

# App:          http://localhost:8000/health/live
# Grafana:      http://localhost:3000  (admin / admin)
# Prometheus:   http://localhost:9091
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
PYTHONPATH=. pytest tests/ -v --cov=app --cov-report=term-missing
```

---

## Chaos Engineering

The app exposes chaos endpoints to simulate real failure modes. Use them to verify alerts fire correctly, practice incident response, and validate the full observability pipeline end-to-end.

### Scenario 1 — Error rate spike

**Simulate:**
```bash
# Inject 20% random 500 errors
curl -X POST http://localhost:8000/chaos/error-rate/0.2
```

**Verify:**
- Prometheus (`http://localhost:9091`): `sum(rate(http_requests_total{status_code=~"5.."}[1m]))` rises above 0
- Alertmanager (`http://localhost:9093`): `SLOErrorBudgetBurnRateCritical` fires within ~2 minutes
- Grafana (`http://localhost:3000`): Error Budget gauge drops, burn rate graph spikes

### Scenario 2 — Latency injection

**Simulate:**
```bash
# Add 300ms artificial latency to every request
curl -X POST http://localhost:8000/chaos/latency/300
```

**Verify:**
- Prometheus: `histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))` exceeds 0.5
- Alertmanager: `SLOLatencyBudgetBurnRateCritical` fires within ~5 minutes
- Grafana: p99 latency panel turns red

### Scenario 3 — Database failure

**Simulate:**
```bash
# Mark database as unavailable
curl -X POST http://localhost:8000/chaos/db-down
```

**Verify:**
- Health probe: `curl http://localhost:8000/health/ready` returns `503`
- Prometheus: `db_up{job="sre-platform"}` drops to `0`
- Any request to `/api/items` returns `503`

### Reset

```bash
curl -X POST http://localhost:8000/chaos/reset
```

> **Note:** `/chaos/reset` must be sent as `POST`. After reset, allow ~60 seconds for the Prometheus 1-minute rate window to clear before alerts resolve.

---

## Tear Down

```bash
# Stop all containers, keep data volumes
docker compose down

# Stop and delete all data volumes (Prometheus TSDB, Grafana state, Loki logs)
docker compose down -v
```

---

## Deploy to AWS

### Prerequisites

- AWS account with appropriate permissions
- Terraform ≥ 1.7
- AWS CLI configured
- kubectl installed
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
# Edit terraform.tfvars — set grafana_admin_password, github_repo, monitoring_allowed_cidrs
```

### 3. Deploy infrastructure

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Terraform provisions the VPC, EKS cluster, ECR repository, GitHub Actions IAM role, and monitoring EC2. Outputs the cluster name, ECR URL, and Grafana URL.

### 4. Configure kubectl

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name $(terraform output -raw eks_cluster_name)

# Verify nodes are ready
kubectl get nodes
```

### 5. Build, push, and deploy the initial image

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $(terraform output -raw ecr_repository_url | cut -d/ -f1)

# Build and push
docker build -t $(terraform output -raw ecr_repository_url):latest ./app
docker push $(terraform output -raw ecr_repository_url):latest

# Inject image and deploy to EKS
sed "s|REPLACE_WITH_ECR_IMAGE|$(terraform output -raw ecr_repository_url):latest|g" \
  k8s/deployment.yml | kubectl apply -f -
kubectl apply -f k8s/

# Wait for pods to be ready
kubectl rollout status deployment/sre-platform --namespace sre-platform
```

### 6. Configure GitHub Actions

Add this secret to your GitHub repository:

| Secret | Value |
|:---|:---|
| `AWS_DEPLOY_ROLE_ARN` | Value of `terraform output github_deploy_role_arn` |

The CI/CD uses OIDC — no long-lived AWS credentials stored in GitHub.

---

## How workflows are triggered | GitHub Actions

This project uses **GitHub Actions** — GitHub's built-in CI/CD platform. Workflows are defined as YAML files in `.github/workflows/` and run on GitHub-hosted virtual machines called **runners** (`ubuntu-latest` here).

Each workflow is made up of **jobs**, which contain **steps**. GitHub detects and registers them automatically when you push to the repo.

Workflow files live in `.github/workflows/` — on Mac, folders starting with `.` are hidden in Finder; press `Cmd + Shift + .` to toggle visibility, or browse them directly in the GitHub UI under the repo's **Actions** tab.

| Workflow | What it does | Trigger |
|:---|:---|:---|
| `ci.yml` | Tests, lint, SAST, Docker build, Terraform validate | Automatically on every push or PR that touches `app/` |
| `deploy.yml` | Build → ECR push → EKS deploy → smoke test | Manually only — go to **Actions → Deploy → Run workflow** in GitHub UI |

> `deploy.yml` requires AWS infrastructure to be provisioned and `AWS_DEPLOY_ROLE_ARN` secret set before use.

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
├── k8s/                        # Kubernetes manifests
│   ├── namespace.yml
│   ├── configmap.yml
│   ├── deployment.yml          # Rolling update, liveness/readiness probes
│   ├── service.yml             # LoadBalancer service
│   └── hpa.yml                 # Horizontal Pod Autoscaler (CPU + memory)
├── terraform/
│   ├── modules/
│   │   ├── networking/         # VPC, subnets, NAT gateways
│   │   ├── eks/                # EKS cluster, node group, ECR, OIDC provider
│   │   ├── monitoring/         # Monitoring EC2, security groups
│   │   └── iam/                # GitHub Actions OIDC deploy role
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
│   └── deploy.yml              # Build → ECR → EKS → smoke test
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

**Why EKS over ECS Fargate?**
EKS gives you the full Kubernetes API — HPA, rolling updates, liveness/readiness probes,
namespace isolation, and a declarative manifest model that's portable across any cloud.
ECS is simpler to operate but is AWS-only and abstracts away primitives that most
platform engineering roles expect you to know. For an SRE portfolio, EKS demonstrates
deeper operational depth.

---

## References

- [Google SRE Book](https://sre.google/sre-book/) — Chapter 4 (SLOs), Chapter 13 (emergency response)
- [Google SRE Workbook](https://sre.google/workbook/alerting-on-slos/) — Multi-window burn rate alerting
- [Prometheus docs](https://prometheus.io/docs/) — Recording rules, alerting rules
- [Grafana docs](https://grafana.com/docs/) — Dashboard provisioning

---

## License

MIT — use freely, attribute appreciated.

---

## 💻 Author

[Vinay Singh](https://vinay-singh-engineer.github.io/portfolio)

---