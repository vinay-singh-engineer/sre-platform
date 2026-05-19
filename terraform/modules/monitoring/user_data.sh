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

# Clone the monitoring configs from the repository
mkdir -p /opt/sre-platform/monitoring
cd /opt/sre-platform

# Write Prometheus config
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

# Write docker-compose for monitoring stack
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
