output "asg_name" {
  description = "Auto Scaling group name."
  value       = aws_autoscaling_group.this.name
}

output "role_name" {
  description = "Instance role name."
  value       = aws_iam_role.this.name
}

output "settings" {
  description = "Security/HA-relevant settings, exposed for tests and review."
  value = {
    image_id          = aws_launch_template.this.image_id
    imds_tokens       = aws_launch_template.this.metadata_options[0].http_tokens
    min_size          = aws_autoscaling_group.this.min_size
    health_check_type = aws_autoscaling_group.this.health_check_type
  }
}
