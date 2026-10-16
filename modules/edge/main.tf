# CloudFront + (optional) ACM certificate and Route 53 alias records.
# Custom-domain resources exist only when BOTH domain_name and hosted_zone_name are set.
# The ACM certificate must be in us-east-1 for CloudFront - this project's (fixed) region.

locals {
  custom_domain = var.domain_name != null && var.hosted_zone_name != null
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

data "aws_route53_zone" "this" {
  count        = local.custom_domain ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = false
}

############################
# ACM + validation
############################
resource "aws_acm_certificate" "cloudfront" {
  count = local.custom_domain ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  # Single-name certificate: key on the static domain, take apply-time values from the one option.
  for_each = local.custom_domain ? toset([var.domain_name]) : toset([])

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = tolist(aws_acm_certificate.cloudfront[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.cloudfront[0].domain_validation_options)[0].resource_record_type
  records         = [tolist(aws_acm_certificate.cloudfront[0].domain_validation_options)[0].resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cloudfront" {
  count = local.custom_domain ? 1 : 0

  certificate_arn         = aws_acm_certificate.cloudfront[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

############################
# CloudFront
############################
resource "aws_cloudfront_distribution" "main" {
  #checkov:skip=CKV_AWS_68:WAF is an optional cost add-on; see README
  #checkov:skip=CKV_AWS_86:Access logging needs an S3 bucket with ACLs enabled; left out of the lab
  #checkov:skip=CKV_AWS_310:Single origin by design; resilience comes from the multi-AZ ALB
  #checkov:skip=CKV_AWS_174:Without a custom domain the default *.cloudfront.net cert cannot enforce a minimum TLS version (AWS limitation); the custom-domain path sets TLSv1.2_2021
  #checkov:skip=CKV_AWS_374:No geo restriction required for this lab
  #checkov:skip=CKV2_AWS_32:Response headers policy is a hardening follow-up; see README
  #checkov:skip=CKV2_AWS_47:WAF is an optional add-on; see README
  default_root_object = "index.html"
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  comment             = "${var.name} web platform"
  price_class         = var.price_class
  aliases             = local.custom_domain ? [var.domain_name] : []

  origin {
    origin_id   = "external-alb"
    domain_name = var.origin_domain_name

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }

    custom_header {
      name  = var.origin_verify_header_name
      value = var.origin_verify_header_value
    }
  }

  # Default: dynamic HTML from the frontend - never cached.
  default_cache_behavior {
    target_origin_id         = "external-alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # API: never cached, all methods, all viewer headers/cookies/query strings forwarded.
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "external-alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # Static assets: cached at the edge (Managed-CachingOptimized).
  ordered_cache_behavior {
    path_pattern           = "/static/*"
    target_origin_id       = "external-alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.custom_domain ? null : true
    acm_certificate_arn            = local.custom_domain ? aws_acm_certificate_validation.cloudfront[0].certificate_arn : null
    ssl_support_method             = local.custom_domain ? "sni-only" : null
    minimum_protocol_version       = local.custom_domain ? "TLSv1.2_2021" : null
  }
}

############################
# Route 53 alias records
############################
resource "aws_route53_record" "a" {
  count = local.custom_domain ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "aaaa" {
  count = local.custom_domain ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
