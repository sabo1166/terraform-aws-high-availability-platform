output "distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.main.id
}

output "distribution_domain_name" {
  description = "PUBLIC: *.cloudfront.net domain."
  value       = aws_cloudfront_distribution.main.domain_name
}

output "public_url" {
  description = "PUBLIC: URL to open in a browser."
  value       = local.custom_domain ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN (null without a custom domain)."
  value       = local.custom_domain ? aws_acm_certificate.cloudfront[0].arn : null
}

output "dns_record_names" {
  description = "Names of the A and AAAA alias records created (empty without a custom domain)."
  value       = concat([for r in aws_route53_record.a : r.name], [for r in aws_route53_record.aaaa : r.name])
}

output "default_viewer_protocol_policy" {
  description = "Viewer protocol policy on the default behavior (for tests/review)."
  value       = aws_cloudfront_distribution.main.default_cache_behavior[0].viewer_protocol_policy
}
