variable "name" {
  description = "Name prefix."
  type        = string
}

variable "origin_domain_name" {
  description = "DNS name of the external ALB (the CloudFront origin)."
  type        = string
}

variable "origin_verify_header_name" {
  description = "Header CloudFront adds to origin requests."
  type        = string
}

variable "origin_verify_header_value" {
  description = "Shared secret value for the origin-verify header."
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Public hostname (e.g. app.example.com); null = *.cloudfront.net only."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Existing public Route 53 zone containing domain_name; null when domain_name is null."
  type        = string
  default     = null
}

variable "price_class" {
  description = "CloudFront price class."
  type        = string
}
