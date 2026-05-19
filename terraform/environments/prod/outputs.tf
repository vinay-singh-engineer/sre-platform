output "eks_cluster_name"    { value = module.eks.cluster_name }
output "eks_cluster_endpoint" { value = module.eks.cluster_endpoint }
output "ecr_repository_url"  { value = module.eks.ecr_repository_url }
output "github_deploy_role_arn" { value = module.iam.github_deploy_role_arn }
output "grafana_url"         { value = module.monitoring.grafana_url }
output "prometheus_url"      { value = module.monitoring.prometheus_url }
output "alertmanager_url"    { value = module.monitoring.alertmanager_url }
