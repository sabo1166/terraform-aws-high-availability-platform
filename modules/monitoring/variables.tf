variable "name" {
  description = "Name prefix."
  type        = string
}

variable "alarm_email" {
  description = "Optional e-mail subscribed to the alarm topic."
  type        = string
  default     = null
}

variable "external_alb_arn_suffix" {
  description = "arn_suffix of the external ALB."
  type        = string
}

variable "internal_alb_arn_suffix" {
  description = "arn_suffix of the internal ALB."
  type        = string
}

variable "frontend_tg_arn_suffix" {
  description = "arn_suffix of the frontend target group."
  type        = string
}

variable "backend_tg_arn_suffix" {
  description = "arn_suffix of the backend target group."
  type        = string
}

variable "frontend_asg_name" {
  description = "Frontend ASG name."
  type        = string
}

variable "backend_asg_name" {
  description = "Backend ASG name."
  type        = string
}

variable "db_identifier" {
  description = "RDS instance identifier."
  type        = string
}

variable "cloudfront_distribution_id" {
  description = "CloudFront distribution ID."
  type        = string
}
