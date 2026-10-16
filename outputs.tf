# No secrets are output. The DB password lives only in the RDS-managed Secrets Manager secret.

output "public_url" {
  description = "PUBLIC: URL to open in a browser."
  value       = module.edge.public_url
}

output "cloudfront_domain_name" {
  description = "PUBLIC: CloudFront *.cloudfront.net domain."
  value       = module.edge.distribution_domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (for invalidations / CLI debugging)."
  value       = module.edge.distribution_id
}

output "external_alb_dns_name" {
  description = "PUBLIC-but-locked: external ALB DNS. Direct requests return 403 (no origin-verify header)."
  value       = aws_lb.external.dns_name
}

output "internal_alb_dns_name" {
  description = "PRIVATE: internal ALB DNS (resolvable only inside the VPC)."
  value       = aws_lb.internal.dns_name
}

output "rds_endpoint" {
  description = "PRIVATE: RDS endpoint (resolves to private IPs; reachable only from backend SG)."
  value       = module.database.endpoint
}

output "rds_master_secret_arn" {
  description = "ARN (not the value) of the RDS-managed Secrets Manager secret."
  value       = module.database.master_secret_arn
}

output "ami_verification" {
  description = "AMI facts as read from AWS at plan time."
  value = {
    id               = data.aws_ami.app.id
    name             = data.aws_ami.app.name
    owner_id         = data.aws_ami.app.owner_id
    architecture     = data.aws_ami.app.architecture
    platform_details = data.aws_ami.app.platform_details
    root_device_name = data.aws_ami.app.root_device_name
    state            = data.aws_ami.app.state
  }
}

output "asg_names" {
  description = "Auto Scaling Group names."
  value = {
    frontend = module.frontend.asg_name
    backend  = module.backend.asg_name
  }
}

output "target_group_arns" {
  description = "Target group ARNs (for describe-target-health)."
  value = {
    frontend = aws_lb_target_group.frontend.arn
    backend  = aws_lb_target_group.backend.arn
  }
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "alarm_topic_arn" {
  description = "SNS topic for CloudWatch alarms."
  value       = module.monitoring.topic_arn
}

output "acm_certificate_arn" {
  description = "ACM certificate used by CloudFront (null when no custom domain)."
  value       = module.edge.acm_certificate_arn
}
