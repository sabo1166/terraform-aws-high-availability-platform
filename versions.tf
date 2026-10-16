terraform {
  # >= 1.10 is required for native S3 state locking (use_lockfile) in backend.tf
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

# State: remote S3 backend declared in backend.tf (partial configuration; see docs/REMOTE_STATE.md).

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
