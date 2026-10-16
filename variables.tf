############################
# General
############################
variable "region" {
  description = "AWS region. Fixed to us-east-1 (CloudFront ACM certificates and CloudFront metrics must live there)."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.region == "us-east-1"
    error_message = "This project targets us-east-1 only (ACM for CloudFront must be in us-east-1)."
  }
}

variable "project_name" {
  description = "Short lowercase name used as a resource-name prefix (max 12 chars; ALB/TG names have a 32 char limit)."
  type        = string
  default     = "ha-web"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.project_name)) && length(var.project_name) >= 2 && length(var.project_name) <= 12
    error_message = "project_name must be 2-12 chars: lowercase letters, digits and single hyphens, starting with a letter, not ending in a hyphen."
  }
}

variable "environment" {
  description = "Environment name (max 8 chars)."
  type        = string
  default     = "lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.environment)) && length(var.environment) >= 2 && length(var.environment) <= 8
    error_message = "environment must be 2-8 chars: lowercase letters, digits and single hyphens, starting with a letter, not ending in a hyphen."
  }
}

############################
# AMI / compute
############################
variable "ami_id" {
  description = "AMI for frontend and backend launch templates. Default is the mandated AMI; it is validated at plan time (state, platform, architecture, instance-type compatibility)."
  type        = string
  default     = "ami-0ed59cbb87dfa8dba"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxx."
  }
}

variable "ami_owner_id" {
  description = "Optional 12-digit AWS account ID expected to own ami_id. When set, plan fails if the AMI has a different owner. Fill it in after checking the AMI with describe-images."
  type        = string
  default     = null

  validation {
    condition     = var.ami_owner_id == null || can(regex("^[0-9]{12}$", var.ami_owner_id))
    error_message = "ami_owner_id must be a 12-digit AWS account ID."
  }
}

variable "frontend_instance_type" {
  description = "Frontend instance type. Must support the AMI architecture (checked at plan time). Use a Graviton type such as t4g.micro only if the AMI is arm64."
  type        = string
  default     = "t3.micro"
}

variable "backend_instance_type" {
  description = "Backend instance type. Must support the AMI architecture (checked at plan time)."
  type        = string
  default     = "t3.micro"
}

variable "frontend_capacity" {
  description = "Frontend ASG sizes. min >= 2 keeps one instance per AZ for HA."
  type = object({
    min     = number
    desired = number
    max     = number
  })
  default = { min = 2, desired = 2, max = 4 }

  validation {
    condition     = var.frontend_capacity.min >= 2 && var.frontend_capacity.min <= var.frontend_capacity.desired && var.frontend_capacity.desired <= var.frontend_capacity.max
    error_message = "Require 2 <= min <= desired <= max."
  }
}

variable "backend_capacity" {
  description = "Backend ASG sizes. min >= 2 keeps one instance per AZ for HA."
  type = object({
    min     = number
    desired = number
    max     = number
  })
  default = { min = 2, desired = 2, max = 4 }

  validation {
    condition     = var.backend_capacity.min >= 2 && var.backend_capacity.min <= var.backend_capacity.desired && var.backend_capacity.desired <= var.backend_capacity.max
    error_message = "Require 2 <= min <= desired <= max."
  }
}

variable "cpu_target_percent" {
  description = "Target-tracking average CPU utilisation for both ASGs."
  type        = number
  default     = 50
}

############################
# Network
############################
variable "vpc_cidr" {
  description = "VPC CIDR block (a /16 is expected; subnets are carved as /24)."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) == 16
    error_message = "vpc_cidr must be a valid /16 CIDR."
  }
}

variable "az_count" {
  description = "Number of Availability Zones to use (2 or 3)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "nat_gateway_mode" {
  description = "per_az = one NAT Gateway per AZ (resilient, ~2x cost). single = one shared NAT (cheaper lab mode; if its AZ fails, ALL private egress is lost)."
  type        = string
  default     = "per_az"

  validation {
    condition     = contains(["per_az", "single"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be per_az or single."
  }
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs (REJECT+ACCEPT) to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for log groups created here."
  type        = number
  default     = 30
}

############################
# Edge: DNS / CloudFront
############################
variable "domain_name" {
  description = "Public hostname served by CloudFront, e.g. app.example.com. null = use the *.cloudfront.net domain (no ACM, no Route 53)."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Existing public Route 53 hosted zone that contains domain_name, e.g. example.com. Required when domain_name is set."
  type        = string
  default     = null
}

variable "origin_verify_header_name" {
  description = "Header CloudFront adds to origin requests; the external ALB rejects requests without the matching value."
  type        = string
  default     = "X-Origin-Verify"
}

variable "cloudfront_price_class" {
  description = "PriceClass_100 (NA/EU, cheapest), PriceClass_200 or PriceClass_All."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "Invalid CloudFront price class."
  }
}

variable "alb_deletion_protection" {
  description = "Enable deletion protection on both ALBs (set false before destroying)."
  type        = bool
  default     = false
}

############################
# Database
############################
variable "db_engine_version" {
  description = "PostgreSQL engine version (major, e.g. \"16\", or full e.g. \"16.4\")."
  type        = string
  default     = "16"
}

variable "db_parameter_group_family" {
  description = "Parameter group family matching db_engine_version."
  type        = string
  default     = "postgres16"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial storage in GiB (gp3 minimum for PostgreSQL is 20)."
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20
    error_message = "db_allocated_storage must be at least 20 GiB for gp3."
  }
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB (0 disables)."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "appdb"
}

variable "db_multi_az" {
  description = "Multi-AZ standby. Keep true; only disable for throwaway cost experiments."
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  description = "Automated backup retention (must be > 0)."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days > 0 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days must be 1-35."
  }
}

variable "db_deletion_protection" {
  description = "RDS deletion protection. Must be set to false and applied BEFORE terraform destroy."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Default false (a snapshot is taken and keeps costing storage until deleted)."
  type        = bool
  default     = false
}

############################
# Alerting
############################
variable "alarm_email" {
  description = "Optional e-mail address subscribed to the alarm SNS topic (needs manual confirmation click)."
  type        = string
  default     = null
}
