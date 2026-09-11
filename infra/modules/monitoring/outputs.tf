output "alert_topic_arn" {
  description = "SNS topic for intrusion alarms"
  value       = aws_sns_topic.alerts.arn
}

output "ssm_sessions_log_group_arn" {
  description = "CloudWatch log group receiving SSM session streams"
  value       = aws_cloudwatch_log_group.ssm_sessions.arn
}
