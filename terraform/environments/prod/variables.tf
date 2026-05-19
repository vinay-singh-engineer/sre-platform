variable "aws_region"    { type = string; default = "us-east-1" }
variable "project"       { type = string; default = "sre-platform" }
variable "environment"   { type = string; default = "prod" }
variable "vpc_cidr"      { type = string; default = "10.0.0.0/16" }
variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}
variable "image_tag"      { type = string; default = "latest" }
variable "desired_count"  { type = number; default = 2 }
variable "min_count"      { type = number; default = 2 }
variable "max_count"      { type = number; default = 10 }
variable "task_cpu"       { type = number; default = 256 }
variable "task_memory"    { type = number; default = 512 }
variable "ec2_key_name"   { type = string; default = null }
variable "grafana_admin_password" { type = string; sensitive = true }
variable "monitoring_allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access monitoring UIs (your office or VPN)"
  default     = ["0.0.0.0/0"]
}
