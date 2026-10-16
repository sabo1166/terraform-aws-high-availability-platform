# Each tier accepts traffic only from the tier before it:
#   CloudFront prefix list -> ext ALB:80 -> frontend:80 -> int ALB:80 -> backend:8080 -> RDS:5432
# App tiers also egress on 80/443 via NAT (packages, SSM). DNS to the VPC resolver is not filtered by SGs.

resource "aws_security_group" "ext_alb" {
  name        = "${local.name}-ext-alb"
  description = "External ALB - ingress only from CloudFront origin-facing IPs"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-ext-alb-sg" }
}

resource "aws_security_group" "frontend" {
  name        = "${local.name}-frontend"
  description = "Frontend instances - ingress only from external ALB"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-frontend-sg" }
}

resource "aws_security_group" "int_alb" {
  name        = "${local.name}-int-alb"
  description = "Internal ALB - ingress only from frontend instances"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-int-alb-sg" }
}

resource "aws_security_group" "backend" {
  name        = "${local.name}-backend"
  description = "Backend instances - ingress only from internal ALB"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-backend-sg" }
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "RDS PostgreSQL - ingress only from backend instances"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-rds-sg" }
}

############################
# External ALB
############################
resource "aws_vpc_security_group_ingress_rule" "ext_alb_from_cloudfront" {
  #checkov:skip=CKV_AWS_260:Source is an SG reference or the CloudFront prefix list, not 0.0.0.0/0 (checkov false positive)
  security_group_id = aws_security_group.ext_alb.id
  description       = "HTTP from CloudFront origin-facing prefix list"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "ext_alb_to_frontend" {
  security_group_id            = aws_security_group.ext_alb.id
  description                  = "To frontend instances"
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

############################
# Frontend
############################
resource "aws_vpc_security_group_ingress_rule" "frontend_from_ext_alb" {
  #checkov:skip=CKV_AWS_260:Source is an SG reference or the CloudFront prefix list, not 0.0.0.0/0 (checkov false positive)
  security_group_id            = aws_security_group.frontend.id
  description                  = "HTTP from external ALB"
  referenced_security_group_id = aws_security_group.ext_alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "frontend_to_int_alb" {
  security_group_id            = aws_security_group.frontend.id
  description                  = "API proxy to internal ALB"
  referenced_security_group_id = aws_security_group.int_alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "frontend_https_out" {
  security_group_id = aws_security_group.frontend.id
  description       = "HTTPS out via NAT (SSM, package repos)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "frontend_http_out" {
  security_group_id = aws_security_group.frontend.id
  description       = "HTTP out via NAT (some distro package mirrors use plain HTTP)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

############################
# Internal ALB
############################
resource "aws_vpc_security_group_ingress_rule" "int_alb_from_frontend" {
  #checkov:skip=CKV_AWS_260:Source is an SG reference or the CloudFront prefix list, not 0.0.0.0/0 (checkov false positive)
  security_group_id            = aws_security_group.int_alb.id
  description                  = "HTTP from frontend instances"
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "int_alb_to_backend" {
  security_group_id            = aws_security_group.int_alb.id
  description                  = "To backend instances"
  referenced_security_group_id = aws_security_group.backend.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

############################
# Backend
############################
resource "aws_vpc_security_group_ingress_rule" "backend_from_int_alb" {
  security_group_id            = aws_security_group.backend.id
  description                  = "App port from internal ALB"
  referenced_security_group_id = aws_security_group.int_alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "backend_to_rds" {
  security_group_id            = aws_security_group.backend.id
  description                  = "PostgreSQL to RDS"
  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "backend_https_out" {
  security_group_id = aws_security_group.backend.id
  description       = "HTTPS out via NAT (SSM, Secrets Manager, package repos)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "backend_http_out" {
  security_group_id = aws_security_group.backend.id
  description       = "HTTP out via NAT (some distro package mirrors use plain HTTP)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

############################
# RDS (no egress rules: the DB initiates no connections)
############################
resource "aws_vpc_security_group_ingress_rule" "rds_from_backend" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from backend instances"
  referenced_security_group_id = aws_security_group.backend.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
