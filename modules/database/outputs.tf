output "address" {
  description = "PRIVATE: DB hostname."
  value       = aws_db_instance.main.address
}

output "port" {
  description = "DB port."
  value       = aws_db_instance.main.port
}

output "endpoint" {
  description = "PRIVATE: host:port."
  value       = aws_db_instance.main.endpoint
}

output "identifier" {
  description = "DB instance identifier (CloudWatch dimension)."
  value       = aws_db_instance.main.identifier
}

output "master_secret_arn" {
  description = "ARN (not the value) of the RDS-managed master secret."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "settings" {
  description = "Security-relevant settings, exposed for tests and review."
  value = {
    multi_az                = aws_db_instance.main.multi_az
    storage_encrypted       = aws_db_instance.main.storage_encrypted
    publicly_accessible     = aws_db_instance.main.publicly_accessible
    backup_retention_period = aws_db_instance.main.backup_retention_period
    deletion_protection     = aws_db_instance.main.deletion_protection
  }
}
