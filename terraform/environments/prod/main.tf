terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    # Configure via -backend-config or terraform.tfbackend
    # bucket = "your-terraform-state-bucket"
    # key    = "sre-platform/prod/terraform.tfstate"
    # region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  name = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "github.com/your-org/sre-platform"
  }
}

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------
module "networking" {
  source = "../../modules/networking"

  name               = local.name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  tags               = local.common_tags
}

module "iam" {
  source      = "../../modules/iam"
  name        = local.name
  github_repo = var.github_repo
  tags        = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  name               = local.name
  vpc_id             = module.networking.vpc_id
  public_subnet_ids  = module.networking.public_subnet_ids
  private_subnet_ids = module.networking.private_subnet_ids

  kubernetes_version = var.kubernetes_version
  node_instance_type = var.node_instance_type
  node_desired_count = var.node_desired_count
  node_min_count     = var.node_min_count
  node_max_count     = var.node_max_count

  tags = local.common_tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  name                   = local.name
  vpc_id                 = module.networking.vpc_id
  subnet_id              = module.networking.public_subnet_ids[0]
  vpc_cidr_blocks        = [var.vpc_cidr]
  allowed_cidr_blocks    = var.monitoring_allowed_cidrs
  app_alb_dns            = var.app_dns
  grafana_admin_password = var.grafana_admin_password
  key_name               = var.ec2_key_name

  tags = local.common_tags
}
