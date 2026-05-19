output "monitoring_public_ip"  { value = aws_eip.monitoring.public_ip }
output "grafana_url"           { value = "http://${aws_eip.monitoring.public_ip}:3000" }
output "prometheus_url"        { value = "http://${aws_eip.monitoring.public_ip}:9090" }
output "alertmanager_url"      { value = "http://${aws_eip.monitoring.public_ip}:9093" }
output "loki_url"              { value = "http://${aws_eip.monitoring.public_ip}:3100" }
