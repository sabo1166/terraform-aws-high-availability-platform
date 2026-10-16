output "topic_arn" {
  description = "SNS topic ARN that receives all alarm notifications."
  value       = aws_sns_topic.alarms.arn
}
