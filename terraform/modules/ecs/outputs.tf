output "cluster_name"      { value = aws_ecs_cluster.main.name }
output "cluster_id"        { value = aws_ecs_cluster.main.id }
output "service_name"      { value = aws_ecs_service.app.name }
output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }
output "alb_dns_name"      { value = aws_lb.main.dns_name }
output "alb_arn"           { value = aws_lb.main.arn }
output "target_group_arn"  { value = aws_lb_target_group.app.arn }
output "log_group_name"    { value = aws_cloudwatch_log_group.app.name }
