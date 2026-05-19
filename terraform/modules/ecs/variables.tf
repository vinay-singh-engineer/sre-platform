variable "name"               { type = string }
variable "vpc_id"             { type = string }
variable "public_subnet_ids"  { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "execution_role_arn" { type = string }
variable "task_role_arn"      { type = string }
variable "environment"        { type = string; default = "production" }
variable "image_tag"          { type = string; default = "latest" }
variable "container_port"     { type = number; default = 8000 }
variable "task_cpu"           { type = number; default = 256 }
variable "task_memory"        { type = number; default = 512 }
variable "desired_count"      { type = number; default = 2 }
variable "min_count"          { type = number; default = 2 }
variable "max_count"          { type = number; default = 10 }
variable "tags"               { type = map(string); default = {} }
