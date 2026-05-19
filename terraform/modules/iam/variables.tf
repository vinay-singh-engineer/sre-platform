variable "name" {
  type = string
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in owner/name format, e.g. vinay-singh-engineer/sre-platform"
}

variable "tags" {
  type    = map(string)
  default = {}
}
