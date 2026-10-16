variable "name" {
  description = "Name prefix."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated DB subnet IDs (at least two AZs)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group attached to the database."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL version."
  type        = string
}

variable "parameter_group_family" {
  description = "Parameter group family matching engine_version."
  type        = string
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "allocated_storage" {
  description = "Initial storage (GiB)."
  type        = number
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling (GiB); 0 disables."
  type        = number
}

variable "db_name" {
  description = "Initial database name."
  type        = string
}

variable "multi_az" {
  description = "Multi-AZ standby."
  type        = bool
}

variable "backup_retention_days" {
  description = "Automated backup retention; must be > 0."
  type        = number

  validation {
    condition     = var.backup_retention_days > 0 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be 1-35."
  }
}

variable "deletion_protection" {
  description = "Deletion protection."
  type        = bool
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy."
  type        = bool
}

variable "log_retention_days" {
  description = "Retention for the RDS CloudWatch log groups."
  type        = number
}
