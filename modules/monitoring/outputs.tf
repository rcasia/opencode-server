output "alert_topic_arn" {
  description = "SNS topic for intrusion alarms"
  value       = aws_sns_topic.alerts.arn
}
