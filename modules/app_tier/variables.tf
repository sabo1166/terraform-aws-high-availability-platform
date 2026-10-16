variable "name" {
  description = "Name prefix (<project>-<environment>)."
  type        = string
}

variable "tier" {
  description = "Tier name, e.g. frontend or backend."
  type        = string
}

variable "ami_id" {
  description = "AMI ID (validated by the root module)."
  type        = string
}

variable "root_device_name" {
  description = "Root device name taken from the AMI (e.g. /dev/xvda)."
  type        = string
}

variable "instance_type" {
  description = "Instance type."
  type        = string
}

variable "user_data" {
  description = "Rendered bootstrap script (plain text; base64-encoded here). Must not contain secrets."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets the ASG spans (>= 2 AZs)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least two subnets (AZs) are required."
  }
}

variable "security_group_ids" {
  description = "Security groups for the instances."
  type        = list(string)
}

variable "target_group_arns" {
  description = "Target groups the ASG registers with."
  type        = list(string)
}

variable "capacity" {
  description = "ASG sizes."
  type = object({
    min     = number
    desired = number
    max     = number
  })

  validation {
    condition     = var.capacity.min >= 2 && var.capacity.min <= var.capacity.desired && var.capacity.desired <= var.capacity.max
    error_message = "Require 2 <= min <= desired <= max."
  }
}

variable "cpu_target_percent" {
  description = "Target-tracking average CPU."
  type        = number
}

variable "secret_arns" {
  description = "Secrets Manager ARNs this tier may read (empty = none)."
  type        = list(string)
  default     = []
}
