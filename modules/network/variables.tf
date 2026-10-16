variable "name" {
  description = "Name prefix for all resources."
  type        = string
}

variable "region" {
  description = "AWS region (used for the S3 gateway endpoint service name)."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR (a /16; subnets are carved as /24)."
  type        = string
}

variable "azs" {
  description = "Availability Zone names to use, in order."
  type        = list(string)
}

variable "nat_gateway_mode" {
  description = "per_az = one NAT per AZ; single = one shared NAT (cheaper, less resilient)."
  type        = string

  validation {
    condition     = contains(["per_az", "single"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be per_az or single."
  }
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs."
  type        = bool
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
}
