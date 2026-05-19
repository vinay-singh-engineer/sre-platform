variable "name"                  { type = string }
variable "vpc_id"                { type = string }
variable "subnet_id"             { type = string }
variable "vpc_cidr_blocks"       { type = list(string) }
variable "allowed_cidr_blocks"   { type = list(string); description = "CIDRs allowed to reach Grafana/Prometheus UI" }
variable "app_alb_dns" {
  type        = string
  description = "DNS of the app load balancer for Prometheus scraping. Set after first kubectl apply."
  default     = ""
}
variable "instance_type"         { type = string; default = "t3.small" }
variable "key_name"              { type = string; default = null }
variable "grafana_admin_password" { type = string; sensitive = true }
variable "loki_retention_hours"  { type = number; default = 720 }
variable "tags"                  { type = map(string); default = {} }
