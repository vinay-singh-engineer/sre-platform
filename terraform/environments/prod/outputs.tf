output "app_url"              { value = "http://${module.ecs.alb_dns_name}" }
output "ecr_repository_url"  { value = module.ecs.ecr_repository_url }
output "ecs_cluster_name"    { value = module.ecs.cluster_name }
output "ecs_service_name"    { value = module.ecs.service_name }
output "grafana_url"         { value = module.monitoring.grafana_url }
output "prometheus_url"      { value = module.monitoring.prometheus_url }
output "alertmanager_url"    { value = module.monitoring.alertmanager_url }
