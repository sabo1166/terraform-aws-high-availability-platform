resource "aws_db_subnet_group" "main" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
  tags       = { Name = "${var.name}-db-subnets" }
}

resource "aws_db_parameter_group" "main" {
  name_prefix = "${var.name}-pg-"
  family      = var.parameter_group_family

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "immediate"
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# RDS creates these log groups itself with no expiry unless they already exist, so create them first.
resource "aws_cloudwatch_log_group" "rds" {
  #checkov:skip=CKV_AWS_158:KMS-encrypting log groups needs a CMK; cost/complexity trade-off for a lab
  #checkov:skip=CKV_AWS_338:Retention is a variable (log_retention_days); 1 year is costly for a lab
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${var.name}-postgres/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_353:Performance Insights is unsupported on db.t3.micro; enable when using a larger class
  identifier = "${var.name}-postgres"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > 0 ? var.max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = "dbadmin"
  # RDS generates the master password and keeps it in Secrets Manager (not in state).
  manage_master_user_password = true

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false
  port                   = 5432

  backup_retention_period   = var.backup_retention_days
  backup_window             = "07:00-08:00"
  maintenance_window        = "sun:08:30-sun:09:30"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-postgres-final"

  auto_minor_version_upgrade          = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.monitoring.arn

  depends_on = [aws_cloudwatch_log_group.rds]
}
