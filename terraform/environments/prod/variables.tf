variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "sre-platform"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in owner/name format, e.g. vinay-singh-engineer/sre-platform"
  default     = "vinay-singh-engineer/sre-platform"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_desired_count" {
  type    = number
  default = 2
}

variable "node_min_count" {
  type    = number
  default = 2
}

variable "node_max_count" {
  type    = number
  default = 5
}

variable "ec2_key_name" {
  type    = string
  default = null
}

variable "monitoring_instance_type" {
  type    = string
  default = "t3.small"
}

variable "loki_retention_hours" {
  type    = number
  default = 720
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

variable "monitoring_allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access monitoring UIs (your office or VPN)"
  default     = ["0.0.0.0/0"]
}

variable "app_dns" {
  type        = string
  description = "DNS of the app load balancer — set after first kubectl apply; leave blank on initial deploy"
  default     = ""
}
