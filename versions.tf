terraform {
  # >= 1.10 is required for native S3 state locking (use_lockfile) in backend.tf.example
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# State: local by default (single-user lab; never commit *.tfstate). For team/CI use,
# copy backend.tf.example to backend.tf - see docs/GITHUB_ACTIONS.md.

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "terraform-aws-high-availability-platform"
    }
  }
}
