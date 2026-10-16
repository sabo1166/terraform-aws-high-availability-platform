# Cross-tier wiring (security groups, ALBs, target groups) is in security_groups.tf and alb.tf.

module "network" {
  source = "./modules/network"

  name               = local.name
  region             = var.region
  vpc_cidr           = var.vpc_cidr
  azs                = local.azs
  nat_gateway_mode   = var.nat_gateway_mode
  enable_flow_logs   = var.enable_flow_logs
  log_retention_days = var.log_retention_days
}

module "database" {
  source = "./modules/database"

  name                   = local.name
  subnet_ids             = module.network.db_subnet_ids
  security_group_id      = aws_security_group.rds.id
  engine_version         = var.db_engine_version
  parameter_group_family = var.db_parameter_group_family
  instance_class         = var.db_instance_class
  allocated_storage      = var.db_allocated_storage
  max_allocated_storage  = var.db_max_allocated_storage
  db_name                = var.db_name
  multi_az               = var.db_multi_az
  backup_retention_days  = var.db_backup_retention_days
  deletion_protection    = var.db_deletion_protection
  skip_final_snapshot    = var.db_skip_final_snapshot
  log_retention_days     = var.log_retention_days
}

module "frontend" {
  source = "./modules/app_tier"

  name               = local.name
  tier               = "frontend"
  ami_id             = var.ami_id
  root_device_name   = data.aws_ami.app.root_device_name
  instance_type      = var.frontend_instance_type
  user_data          = replace(templatefile("${path.module}/templates/frontend_user_data.sh.tftpl", { internal_alb_dns = aws_lb.internal.dns_name }), "\r", "")
  subnet_ids         = module.network.app_subnet_ids
  security_group_ids = [aws_security_group.frontend.id]
  target_group_arns  = [aws_lb_target_group.frontend.arn]
  capacity           = var.frontend_capacity
  cpu_target_percent = var.cpu_target_percent

  # ELB health checks need the target group attached to a listener before instances launch.
  depends_on = [terraform_data.preflight, aws_lb_listener_rule.external_from_cloudfront]
}

module "backend" {
  source = "./modules/app_tier"

  name             = local.name
  tier             = "backend"
  ami_id           = var.ami_id
  root_device_name = data.aws_ami.app.root_device_name
  instance_type    = var.backend_instance_type
  user_data = replace(templatefile("${path.module}/templates/backend_user_data.sh.tftpl", {
    db_host = module.database.address
    db_port = module.database.port
  }), "\r", "")
  subnet_ids         = module.network.app_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
  target_group_arns  = [aws_lb_target_group.backend.arn]
  capacity           = var.backend_capacity
  cpu_target_percent = var.cpu_target_percent
  # Backend may read the RDS-managed master secret; the sample app does not use it yet.
  secret_arns = [module.database.master_secret_arn]

  depends_on = [terraform_data.preflight, aws_lb_listener.internal_http]
}

module "edge" {
  source = "./modules/edge"

  name                       = local.name
  origin_domain_name         = aws_lb.external.dns_name
  origin_verify_header_name  = var.origin_verify_header_name
  origin_verify_header_value = random_password.origin_verify.result
  domain_name                = var.domain_name
  hosted_zone_name           = var.hosted_zone_name
  price_class                = var.cloudfront_price_class
}

module "monitoring" {
  source = "./modules/monitoring"

  name                       = local.name
  alarm_email                = var.alarm_email
  external_alb_arn_suffix    = aws_lb.external.arn_suffix
  internal_alb_arn_suffix    = aws_lb.internal.arn_suffix
  frontend_tg_arn_suffix     = aws_lb_target_group.frontend.arn_suffix
  backend_tg_arn_suffix      = aws_lb_target_group.backend.arn_suffix
  frontend_asg_name          = module.frontend.asg_name
  backend_asg_name           = module.backend.asg_name
  db_identifier              = module.database.identifier
  cloudfront_distribution_id = module.edge.distribution_id
}
