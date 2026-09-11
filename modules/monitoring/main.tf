# Intrusion alerting (ADR-0006, ADR-0014): Caddy 401 bursts (backend basic
# probing — now machine-only behind SSO) and 403 bursts (SSO deny: wrong
# GitHub user or oauth2-proxy rejection) plus sshd failures ship to
# CloudWatch Logs via the agent (see compute/user_data.sh); metric filters
# turn them into alarms that email the operator. Browsers never see the
# backend 401 anymore (logged-out SSO redirects instead), so the 403
# filter is the human-gate signal.

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = "alias/aws/sns"
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

resource "aws_cloudwatch_log_metric_filter" "oauth_deny" {
  name           = "${var.name_prefix}-oauth-deny"
  log_group_name = aws_cloudwatch_log_group.caddy.name
  pattern        = "{ $.status = 403 }"

  metric_transformation {
    name      = "${var.name_prefix}-oauth-deny-count"
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

resource "aws_cloudwatch_log_metric_filter" "server_error" {
  name           = "${var.name_prefix}-server-error"
  log_group_name = aws_cloudwatch_log_group.caddy.name
  pattern        = "{ $.status >= 500 }"

  metric_transformation {
    name      = "${var.name_prefix}-server-error-count"
    namespace = var.name_prefix
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "login_probe" {
  alarm_name          = "${var.name_prefix}-login-probe"
  alarm_description   = "Bursts of HTTP 401 on the backend: possible basic-auth brute force behind SSO"
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

resource "aws_cloudwatch_metric_alarm" "oauth_deny" {
  alarm_name          = "${var.name_prefix}-oauth-deny"
  alarm_description   = "Bursts of HTTP 403 at the SSO gate: possible GitHub login abuse"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.oauth_deny.metric_transformation[0].name
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

# Fast-burn twin of login_probe: 10 backend 401s in 1 minute pages sooner
# on credential-stuffing bursts while the 20/5min alarm keeps watch for
# low-and-slow probing.
resource "aws_cloudwatch_metric_alarm" "login_probe_fast" {
  alarm_name          = "${var.name_prefix}-login-probe-fast"
  alarm_description   = "Fast burst of HTTP 401 on the backend (>=10/min): possible brute force behind SSO"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.login_401.metric_transformation[0].name
  namespace           = var.name_prefix
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "ignore"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Backend 5xx bursts on the Caddy log group: the app (not the edge) is
# failing. Threshold is generous to stay quiet on single blips.
resource "aws_cloudwatch_metric_alarm" "server_error" {
  alarm_name          = "${var.name_prefix}-server-error"
  alarm_description   = "Bursts of HTTP 5xx from Caddy: possible app failure behind the edge"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.server_error.metric_transformation[0].name
  namespace           = var.name_prefix
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "ignore"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Sustained CPU pressure on the single host. Wired via instance_id; empty
# (default) keeps the alarm out so fail-open plans without the wiring.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count               = var.instance_id != "" ? 1 : 0
  alarm_name          = "${var.name_prefix}-cpu-high"
  alarm_description   = "EC2 CPU above 80% for 15 minutes: host under sustained load"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 900
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "ignore"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.instance_id
  }
}

# External uptime probe: Route53 hits the public readiness gate /ready
# every 30s and pages on 3 consecutive failures (~$0.50/mo). /ready
# answers 200 only when a backend color answers behind the edge
# (ADR-0015), so this pages on app failure too — not just edge failure.
# /ping stays as the edge-local diagnostic (tells edge apart from app).
# Neither path goes through forward_auth, so probes stay out of the deny
# metrics.
resource "aws_route53_health_check" "site" {
  count             = var.domain_name != "" ? 1 : 0
  type              = "HTTPS"
  fqdn              = var.domain_name
  resource_path     = "/ready"
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
