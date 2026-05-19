#!/bin/bash
set -euo pipefail

# Install Docker + Docker Compose
dnf update -y
dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user

curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create directory structure
mkdir -p /opt/sre-platform/monitoring/alerts
mkdir -p /opt/sre-platform/monitoring/grafana/provisioning/datasources
mkdir -p /opt/sre-platform/monitoring/grafana/provisioning/dashboards
mkdir -p /opt/sre-platform/monitoring/grafana/dashboards

# ---------------------------------------------------------------------------
# Prometheus config
# ---------------------------------------------------------------------------
cat > /opt/sre-platform/monitoring/prometheus.yml << 'PROMEOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    environment: production

rule_files:
  - /etc/prometheus/alerts/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: sre-platform-app
    metrics_path: /metrics
    static_configs:
      - targets: ["${prometheus_url}"]
    relabel_configs:
      - target_label: job
        replacement: sre-platform

  - job_name: node
    static_configs:
      - targets: ["localhost:9100"]
PROMEOF

# ---------------------------------------------------------------------------
# SLO alert rules
# ---------------------------------------------------------------------------
cat > /opt/sre-platform/monitoring/alerts/slo_alerts.yml << 'ALERTEOF'
groups:
  - name: slo.availability
    interval: 1m
    rules:
      - record: job:http_requests_total:rate5m
        expr: rate(http_requests_total[5m])

      - record: job:http_errors_total:rate5m
        expr: rate(http_requests_total{status_code=~"5.."}[5m])

      - record: job:http_error_ratio:rate5m
        expr: |
          sum(rate(http_requests_total{status_code=~"5.."}[5m])) by (job)
          /
          sum(rate(http_requests_total[5m])) by (job)

      - record: job:http_error_ratio:rate1h
        expr: |
          sum(rate(http_requests_total{status_code=~"5.."}[1h])) by (job)
          /
          sum(rate(http_requests_total[1h])) by (job)

      - record: job:http_error_ratio:rate6h
        expr: |
          sum(rate(http_requests_total{status_code=~"5.."}[6h])) by (job)
          /
          sum(rate(http_requests_total[6h])) by (job)

      - record: job:http_error_ratio:rate24h
        expr: |
          sum(rate(http_requests_total{status_code=~"5.."}[24h])) by (job)
          /
          sum(rate(http_requests_total[24h])) by (job)

      - record: job:http_error_ratio:rate3d
        expr: |
          sum(rate(http_requests_total{status_code=~"5.."}[3d])) by (job)
          /
          sum(rate(http_requests_total[3d])) by (job)

      - record: job:slo_error_budget_remaining:rate30d
        expr: |
          1 - (
            sum(rate(http_requests_total{status_code=~"5.."}[30d])) by (job)
            /
            sum(rate(http_requests_total[30d])) by (job)
          ) / (1 - 0.999)

      - alert: SLOErrorBudgetBurnRateCritical
        expr: |
          job:http_error_ratio:rate1h{job="sre-platform"} > (14.4 * 0.001)
          and
          job:http_error_ratio:rate5m{job="sre-platform"} > (14.4 * 0.001)
        for: 2m
        labels:
          severity: critical
          slo: availability
          team: sre
        annotations:
          summary: "CRITICAL: SLO error budget burning fast"
          description: >
            Error rate is {{ $value | humanizePercentage }} over the last hour.
            At this burn rate (14.4x), 2% of the monthly error budget is consumed per hour.
          runbook_url: "https://github.com/your-org/sre-platform/blob/main/runbooks/high-error-rate.md"

      - alert: SLOErrorBudgetBurnRateHigh
        expr: |
          job:http_error_ratio:rate6h{job="sre-platform"} > (6 * 0.001)
          and
          job:http_error_ratio:rate1h{job="sre-platform"} > (6 * 0.001)
        for: 15m
        labels:
          severity: warning
          slo: availability
          team: sre
        annotations:
          summary: "WARNING: SLO error budget burn rate elevated"
          description: >
            Error rate is {{ $value | humanizePercentage }} over 6h.
            At this rate (6x), 5% of the monthly error budget is consumed every 6 hours.
          runbook_url: "https://github.com/your-org/sre-platform/blob/main/runbooks/high-error-rate.md"

      - alert: SLOErrorBudgetAlmostExhausted
        expr: job:slo_error_budget_remaining:rate30d{job="sre-platform"} < 0.10
        for: 5m
        labels:
          severity: warning
          slo: availability
          team: sre
        annotations:
          summary: "Error budget below 10% for the month"
          description: >
            Only {{ $value | humanizePercentage }} of the 30-day error budget remains.

  - name: slo.latency
    interval: 1m
    rules:
      - record: job:http_request_p99_seconds:rate5m
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (job, le)
          )

      - record: job:http_request_p99_seconds:rate1h
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[1h])) by (job, le)
          )

      - alert: SLOLatencyBudgetBurnRateCritical
        expr: |
          job:http_request_p99_seconds:rate5m{job="sre-platform"} > 0.5
          and
          job:http_request_p99_seconds:rate1h{job="sre-platform"} > 0.5
        for: 5m
        labels:
          severity: critical
          slo: latency
          team: sre
        annotations:
          summary: "CRITICAL: p99 latency exceeds SLO threshold (500ms)"
          description: >
            p99 request latency is {{ $value | humanizeDuration }} over the last 5 minutes.

      - alert: SLOLatencyBudgetBurnRateWarning
        expr: job:http_request_p99_seconds:rate1h{job="sre-platform"} > 0.25
        for: 15m
        labels:
          severity: warning
          slo: latency
          team: sre
        annotations:
          summary: "WARNING: p99 latency elevated (>250ms, SLO target 500ms)"
          description: >
            p99 latency is {{ $value | humanizeDuration }} — approaching SLO threshold.
ALERTEOF

# ---------------------------------------------------------------------------
# Infrastructure alert rules
# ---------------------------------------------------------------------------
cat > /opt/sre-platform/monitoring/alerts/infra_alerts.yml << 'INFRAEOF'
groups:
  - name: infrastructure
    rules:
      - alert: ServiceDown
        expr: up{job="sre-platform"} == 0
        for: 1m
        labels:
          severity: critical
          team: sre
        annotations:
          summary: "Service {{ $labels.job }} is DOWN"
          description: "Prometheus cannot scrape {{ $labels.instance }}."

      - alert: HighErrorRate
        expr: |
          sum(rate(http_requests_total{status_code=~"5..",job="sre-platform"}[5m]))
          /
          sum(rate(http_requests_total{job="sre-platform"}[5m])) > 0.05
        for: 3m
        labels:
          severity: warning
          team: sre
        annotations:
          summary: "Error rate above 5% for {{ $labels.job }}"
          description: "HTTP 5xx rate is {{ $value | humanizePercentage }} over 5 minutes."

      - alert: ReadinessProbeFailure
        expr: |
          sum(rate(http_requests_total{endpoint="/health/ready",status_code="503"}[5m])) > 0
        for: 2m
        labels:
          severity: critical
          team: sre
        annotations:
          summary: "Readiness probe returning 503"
          description: "The /health/ready endpoint is failing."

      - alert: HighMemoryUsage
        expr: |
          (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.90
        for: 5m
        labels:
          severity: warning
          team: sre
        annotations:
          summary: "Node memory usage above 90% on {{ $labels.instance }}"
          description: "Memory utilization is {{ $value | humanizePercentage }}."

      - alert: HighCPUUsage
        expr: |
          100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 10m
        labels:
          severity: warning
          team: sre
        annotations:
          summary: "High CPU on {{ $labels.instance }}"
          description: "CPU usage at {{ $value }}% for 10 minutes."

      - alert: DiskSpaceLow
        expr: |
          (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.15
        for: 5m
        labels:
          severity: warning
          team: sre
        annotations:
          summary: "Disk space below 15% on {{ $labels.instance }}"
          description: "Only {{ $value | humanizePercentage }} of disk space remains."

      - alert: PrometheusScrapeFailing
        expr: up == 0
        for: 5m
        labels:
          severity: warning
          team: sre
        annotations:
          summary: "Prometheus cannot scrape {{ $labels.job }} ({{ $labels.instance }})"
          description: "Scrape target has been down for 5 minutes."
INFRAEOF

# ---------------------------------------------------------------------------
# Alertmanager config
# ---------------------------------------------------------------------------
cat > /opt/sre-platform/monitoring/alertmanager.yml << 'AMEOF'
route:
  receiver: default
  group_by: [alertname, job, severity]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    - match:
        severity: critical
        slo: availability
      receiver: pagerduty-critical
      repeat_interval: 1h
    - match:
        severity: critical
      receiver: pagerduty-critical
      repeat_interval: 1h
    - match:
        severity: warning
      receiver: slack-warnings
      repeat_interval: 6h

receivers:
  - name: default
    webhook_configs:
      - url: "http://alert-echo:5001"
        send_resolved: true
  - name: pagerduty-critical
    webhook_configs:
      - url: "http://alert-echo:5001"
        send_resolved: true
  - name: slack-warnings
    webhook_configs:
      - url: "http://alert-echo:5001"
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: critical
    target_match:
      severity: warning
    equal: [alertname, job]
AMEOF

# ---------------------------------------------------------------------------
# Loki config
# ---------------------------------------------------------------------------
cat > /opt/sre-platform/monitoring/loki-config.yml << LOKIEOF
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

ruler:
  alertmanager_url: http://alertmanager:9093

limits_config:
  retention_period: ${loki_retention_hours}h

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem
LOKIEOF

# ---------------------------------------------------------------------------
# Grafana provisioning — datasources
# ---------------------------------------------------------------------------
cat > /opt/sre-platform/monitoring/grafana/provisioning/datasources/datasources.yml << 'DSEOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: false
    jsonData:
      maxLines: 1000
DSEOF

# ---------------------------------------------------------------------------
# Grafana provisioning — dashboard loader
# ---------------------------------------------------------------------------
cat > /opt/sre-platform/monitoring/grafana/provisioning/dashboards/dashboards.yml << 'DBPEOF'
apiVersion: 1
providers:
  - name: SRE Platform Dashboards
    orgId: 1
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
DBPEOF

# ---------------------------------------------------------------------------
# Grafana dashboard JSON
# ---------------------------------------------------------------------------
cat > /opt/sre-platform/monitoring/grafana/dashboards/slo_dashboard.json << 'JSONEOF'
{
  "__inputs": [],
  "__requires": [],
  "annotations": { "list": [] },
  "description": "SLO dashboard: availability error budget burn rate, request rate, latency, and error budget remaining. Based on the Google SRE Workbook multi-window approach.",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
      "id": 1,
      "title": "SLO Summary",
      "type": "row"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "orange", "value": 50 },
              { "color": "green", "value": 90 }
            ]
          },
          "unit": "percent",
          "min": 0,
          "max": 100
        }
      },
      "gridPos": { "h": 6, "w": 6, "x": 0, "y": 1 },
      "id": 2,
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "auto",
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "title": "Error Budget Remaining (30d)",
      "type": "gauge",
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "clamp_min(clamp_max(\n  (1 - (\n    (sum(increase(http_requests_total{status_code=~\"5..\",job=\"sre-platform\"}[30d])) or vector(0))\n    /\n    sum(increase(http_requests_total{job=\"sre-platform\"}[30d]))\n  ) / (1 - 0.999)\n) * 100, 0), 100)",
          "legendFormat": "Budget %",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "orange", "value": 0.001 },
              { "color": "red", "value": 0.01 }
            ]
          },
          "unit": "percentunit",
          "decimals": 3
        }
      },
      "gridPos": { "h": 6, "w": 6, "x": 6, "y": 1 },
      "id": 3,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "orientation": "auto",
        "reduceOptions": { "calcs": ["lastNotNull"] }
      },
      "title": "Error Rate (5m)",
      "type": "stat",
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "(sum(rate(http_requests_total{status_code=~\"5..\",job=\"sre-platform\"}[5m])) or vector(0)) / sum(rate(http_requests_total{job=\"sre-platform\"}[5m]))",
          "legendFormat": "Error Rate",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "orange", "value": 0.25 },
              { "color": "red", "value": 0.5 }
            ]
          },
          "unit": "s",
          "decimals": 3
        }
      },
      "gridPos": { "h": 6, "w": 6, "x": 12, "y": 1 },
      "id": 4,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "reduceOptions": { "calcs": ["lastNotNull"] }
      },
      "title": "p99 Latency (5m)",
      "type": "stat",
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job=\"sre-platform\"}[5m])) by (le))",
          "legendFormat": "p99",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "orange", "value": 1 },
              { "color": "red", "value": 14.4 }
            ]
          },
          "decimals": 2
        }
      },
      "gridPos": { "h": 6, "w": 6, "x": 18, "y": 1 },
      "id": 5,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto",
        "reduceOptions": { "calcs": ["lastNotNull"] }
      },
      "title": "Burn Rate (1h window)",
      "type": "stat",
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "(\n  (sum(rate(http_requests_total{status_code=~\"5..\",job=\"sre-platform\"}[1h])) or vector(0))\n  /\n  sum(rate(http_requests_total{job=\"sre-platform\"}[1h]))\n) / 0.001",
          "legendFormat": "Burn Rate",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 7 },
      "id": 10,
      "title": "RED Metrics — Rate, Errors, Duration",
      "type": "row"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "palette-classic" },
          "custom": { "lineWidth": 2 },
          "unit": "reqps"
        }
      },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "id": 11,
      "options": { "tooltip": { "mode": "multi" } },
      "title": "Request Rate by Status Code",
      "type": "timeseries",
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (status_code) (rate(http_requests_total{job=\"sre-platform\"}[1m]))",
          "legendFormat": "HTTP {{ status_code }}",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "palette-classic" },
          "custom": { "lineWidth": 2 },
          "unit": "s"
        }
      },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "id": 12,
      "options": { "tooltip": { "mode": "multi" } },
      "title": "Request Latency Percentiles",
      "type": "timeseries",
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{job=\"sre-platform\"}[5m])) by (le))",
          "legendFormat": "p50",
          "refId": "A"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job=\"sre-platform\"}[5m])) by (le))",
          "legendFormat": "p95",
          "refId": "B"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job=\"sre-platform\"}[5m])) by (le))",
          "legendFormat": "p99",
          "refId": "C"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 16 },
      "id": 20,
      "title": "Error Budget",
      "type": "row"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "palette-classic" },
          "custom": {
            "lineWidth": 2,
            "fillOpacity": 20
          },
          "unit": "percentunit",
          "min": 0,
          "max": 1
        }
      },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 17 },
      "id": 21,
      "options": { "tooltip": { "mode": "multi" } },
      "title": "Error Budget Burn Rate (multi-window)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "(sum(rate(http_requests_total{status_code=~\"5..\",job=\"sre-platform\"}[1h])) or vector(0)) / sum(rate(http_requests_total{job=\"sre-platform\"}[1h]))",
          "legendFormat": "Error ratio (1h)",
          "refId": "A"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "(sum(rate(http_requests_total{status_code=~\"5..\",job=\"sre-platform\"}[6h])) or vector(0)) / sum(rate(http_requests_total{job=\"sre-platform\"}[6h]))",
          "legendFormat": "Error ratio (6h)",
          "refId": "B"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "0.001",
          "legendFormat": "SLO threshold (0.1%)",
          "refId": "C"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "14.4 * 0.001",
          "legendFormat": "Critical burn threshold (14.4x)",
          "refId": "D"
        }
      ]
    }
  ],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["sre", "slo", "production"],
  "templating": { "list": [] },
  "time": { "from": "now-3h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "SRE Platform — SLO Dashboard",
  "uid": "sre-slo",
  "version": 1
}
JSONEOF

# ---------------------------------------------------------------------------
# Docker Compose for the full monitoring stack
# ---------------------------------------------------------------------------
cat > /opt/sre-platform/docker-compose.yml << 'DCEOF'
services:
  prometheus:
    image: prom/prometheus:v2.52.0
    container_name: prometheus
    volumes:
      - /opt/sre-platform/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /opt/sre-platform/monitoring/alerts:/etc/prometheus/alerts:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=15d"
      - "--web.enable-lifecycle"
    ports:
      - "9090:9090"
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: alertmanager
    volumes:
      - /opt/sre-platform/monitoring/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    ports:
      - "9093:9093"
    restart: unless-stopped

  grafana:
    image: grafana/grafana:10.4.2
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_password}
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - /opt/sre-platform/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
      - /opt/sre-platform/monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana_data:/var/lib/grafana
    ports:
      - "3000:3000"
    restart: unless-stopped

  loki:
    image: grafana/loki:3.0.0
    container_name: loki
    volumes:
      - /opt/sre-platform/monitoring/loki-config.yml:/etc/loki/loki-config.yml:ro
      - loki_data:/loki
    command: -config.file=/etc/loki/loki-config.yml
    ports:
      - "3100:3100"
    restart: unless-stopped

  node-exporter:
    image: prom/node-exporter:v1.8.0
    container_name: node-exporter
    command:
      - "--path.rootfs=/host"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"
    volumes:
      - /:/host:ro,rslave
    ports:
      - "9100:9100"
    restart: unless-stopped

volumes:
  prometheus_data:
  grafana_data:
  loki_data:
DCEOF

# Start the stack
cd /opt/sre-platform
docker-compose up -d

echo "Monitoring stack started at $(date)" >> /var/log/sre-platform-init.log
