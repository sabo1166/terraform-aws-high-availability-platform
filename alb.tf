# High-entropy shared secret between CloudFront and the external ALB.
# Lives in Terraform state (sensitive) and in the CloudFront config. Rotate with:
#   terraform apply -replace=random_password.origin_verify
resource "random_password" "origin_verify" {
  length  = 48
  special = false
}

############################
# External (internet-facing) ALB
############################
resource "aws_lb" "external" {
  #checkov:skip=CKV_AWS_91:ALB access logs need an S3 bucket + policy; optional follow-up, see README
  #checkov:skip=CKV_AWS_150:Deletion protection is a variable (alb_deletion_protection) defaulted off for lab teardown
  #checkov:skip=CKV2_AWS_20:Listener intentionally HTTP-only behind CloudFront (viewer HTTP->HTTPS redirect is enforced at CloudFront)
  #checkov:skip=CKV2_AWS_28:WAF is an optional cost add-on; see README
  name                       = "${local.name}-ext-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.ext_alb.id]
  subnets                    = module.network.public_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = var.alb_deletion_protection

  depends_on = [module.network]
}

resource "aws_lb_target_group" "frontend" {
  #checkov:skip=CKV_AWS_378:ALB-to-frontend leg is HTTP inside private subnets by design; see README known limitations
  name                 = "${local.name}-fe-tg"
  vpc_id               = module.network.vpc_id
  port                 = 80
  protocol             = "HTTP"
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "external_http" {
  #checkov:skip=CKV_AWS_2:CloudFront-to-ALB leg is HTTP by design in this lab; see README known limitations
  #checkov:skip=CKV_AWS_103:TLS policy not applicable to an HTTP listener
  load_balancer_arn = aws_lb.external.arn
  port              = 80
  protocol          = "HTTP"

  # Default: anyone who did not come through CloudFront gets 403.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "external_from_cloudfront" {
  listener_arn = aws_lb_listener.external_http.arn
  priority     = 10

  condition {
    http_header {
      http_header_name = var.origin_verify_header_name
      values           = [random_password.origin_verify.result]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

############################
# Internal ALB (frontend -> backend)
############################
resource "aws_lb" "internal" {
  #checkov:skip=CKV_AWS_91:ALB access logs need an S3 bucket + policy; optional follow-up, see README
  #checkov:skip=CKV_AWS_150:Deletion protection is a variable (alb_deletion_protection) defaulted off for lab teardown
  #checkov:skip=CKV2_AWS_20:Internal ALB, HTTP-only by design in this lab
  name                       = "${local.name}-int-alb"
  load_balancer_type         = "application"
  internal                   = true
  security_groups            = [aws_security_group.int_alb.id]
  subnets                    = module.network.app_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = var.alb_deletion_protection
}

resource "aws_lb_target_group" "backend" {
  #checkov:skip=CKV_AWS_378:ALB-to-backend leg is HTTP inside private subnets by design; see README known limitations
  name                 = "${local.name}-be-tg"
  vpc_id               = module.network.vpc_id
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "internal_http" {
  #checkov:skip=CKV_AWS_2:Internal east-west leg inside private subnets; HTTP by design in this lab
  #checkov:skip=CKV_AWS_103:TLS policy not applicable to an HTTP listener
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
