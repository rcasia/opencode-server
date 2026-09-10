# Intrusion alerting (ADR-0006): Caddy 401 bursts (login probing) and sshd
# failures ship to CloudWatch Logs via the agent (see compute/user_data.sh);
# metric filters turn them into alarms that email the operator.

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_log_group" "caddy" {
  name              = "${var.name_prefix}-caddy"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "secure" {
  name              = "${var.name_prefix}-secure"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "boot" {
  name              = "${var.name_prefix}-boot"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "containers" {
  name              = "${var.name_prefix}-containers"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_metric_filter" "login_401" {
  name           = "${var.name_prefix}-login-401"
  log_group_name = aws_cloudwatch_log_group.caddy.name
  pattern        = "{ $.status = 401 }"

  metric_transformation {
    name      = "${var.name_prefix}-login-401-count"
    namespace = var.name_prefix
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "ssh_failure" {
  name           = "${var.name_prefix}-ssh-failure"
  log_group_name = aws_cloudwatch_log_group.secure.name
  pattern        = "?Failed ?\"Failed password\" ?\"Invalid user\" ?\"authentication failure\""

  metric_transformation {
    name      = "${var.name_prefix}-ssh-failure-count"
    namespace = var.name_prefix
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "login_probe" {
  alarm_name          = "${var.name_prefix}-login-probe"
  alarm_description   = "Bursts of HTTP 401 on opencode web: possible login brute force"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.login_401.metric_transformation[0].name
  namespace           = var.name_prefix
  period              = 300
  statistic           = "Sum"
  threshold           = 20
  treat_missing_data  = "ignore"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ssh_probe" {
  alarm_name          = "${var.name_prefix}-ssh-probe"
  alarm_description   = "Repeated sshd failures: possible SSH brute force"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.ssh_failure.metric_transformation[0].name
  namespace           = var.name_prefix
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  treat_missing_data  = "ignore"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# External uptime probe: Route53 hits the unauthenticated /ping every 30s
# and pages on 3 consecutive failures (~$0.50/mo). /ping never touches
# opencode, so probes stay out of the 401 login-probe metric.
resource "aws_route53_health_check" "site" {
  count             = var.domain_name != "" ? 1 : 0
  type              = "HTTPS"
  fqdn              = var.domain_name
  resource_path     = "/ping"
  port              = 443
  request_interval  = 30
  failure_threshold = 3
  enable_sni        = true

  tags = { Name = "${var.name_prefix}-site" }
}

resource "aws_cloudwatch_metric_alarm" "site_down" {
  count               = var.domain_name != "" ? 1 : 0
  alarm_name          = "${var.name_prefix}-site-down"
  alarm_description   = "Public site not answering HTTPS: instance, boot, or app failure"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.site[0].id
  }
}
