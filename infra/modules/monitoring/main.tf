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

# NOTE (issue #55): no containers log group on purpose. Agent stdout
# carries prompts, code, and echoed secrets; shipping it off-host would
# retain them account-wide. Backend logs stay local (`docker logs`,
# daemon-capped 10m x3). No metric filter ever read this group.

# SSM session audit (issue #54): SSM is the only interactive path to the
# host, and CloudTrail records only that a session existed — not what
# was typed. This customer-owned Session document makes every shell
# session stream to its own log group (90-day retention). Encryption
# stays CloudWatch-default SSE like every other group here (no CMK:
# cheap by design, rule 8); runAs drops sessions to ssm-user, which
# user_data creates at boot with sudo (the pty stream still logs
# everything, so sudo does not blind the audit).
resource "aws_cloudwatch_log_group" "ssm_sessions" {
  name              = "${var.name_prefix}-ssm-sessions"
  retention_in_days = 90
}

resource "aws_ssm_document" "session_logging" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "${var.name_prefix}: stream shell sessions to CloudWatch (issue #54)"
    sessionType   = "Standard_Stream"
    inputs = {
      cloudWatchLogGroupName      = aws_cloudwatch_log_group.ssm_sessions.name
      cloudWatchEncryptionEnabled = false
      cloudWatchStreamingEnabled  = true
      idleSessionTimeout          = "20"
      runAsEnabled                = true
      runAsDefaultUser            = "ssm-user"
    }
  })
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

# Sustained CPU pressure on the single host. No count gate: count must be
# plan-time known and the instance ID is computed, so the alarm always
# exists wherever the module is wired (root main.tf passes the ID).
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
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

# Host health (ADR-0019): the data disk (/var/lib/docker, ADR-0008) fills
# silently — images, sessions, Caddy logs. The CloudWatch agent ships
# mem_used_percent + disk used_percent with append_dimensions InstanceId
# (see app/host/monitoring.sh); these alarms page the same SNS topic as
# the intrusion alarms. Thresholds are vars so the operator can tune
# without editing the module. treat_missing_data is breaching (issue
# #42): a silently dead agent must page, not hide in INSUFFICIENT_DATA.
resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "${var.name_prefix}-disk-high"
  alarm_description   = "Data disk /var/lib/docker above ${var.disk_threshold_percent}%: prune timer or log rotation is losing"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Maximum"
  threshold           = var.disk_threshold_percent
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.instance_id
    path       = "/var/lib/docker"
  }
}

# Host auto-recovery (issue #47): a single instance on failed underlying
# hardware is a manual restart after the site-down page. EC2 recovery is
# free and keeps instance ID, EIP, and the attached data volume; a failed
# instance check (guest OS) gets a reboot instead. Both supported on t3
# with EBS-only storage.
resource "aws_cloudwatch_metric_alarm" "system_check" {
  alarm_name          = "${var.name_prefix}-system-check"
  alarm_description   = "EC2 system status check failed: recover to healthy hardware"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed_System"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "ignore"
  alarm_actions       = ["arn:aws:automate:${var.aws_region}:ec2:recover", aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "instance_check" {
  alarm_name          = "${var.name_prefix}-instance-check"
  alarm_description   = "EC2 instance status check failed: reboot the guest"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed_Instance"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "ignore"
  alarm_actions       = ["arn:aws:automate:${var.aws_region}:ec2:reboot", aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "mem_high" {
  alarm_name          = "${var.name_prefix}-mem-high"
  alarm_description   = "EC2 memory above ${var.mem_threshold_percent}% for 15 minutes: host may OOM the agent backend"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = var.mem_threshold_percent
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.instance_id
  }
}

# Audit trail (single-region, management events): who-called-what for the
# account in this region, delivered to a dedicated bucket. Log-file
# validation on; single region keeps it at cents per month.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "audit" {
  bucket        = "${var.name_prefix}-audit-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.allow_full_destroy

  tags = { Name = "${var.name_prefix}-audit" }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # Empty filter = whole bucket (provider v5 warns without one).
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

data "aws_iam_policy_document" "audit" {
  statement {
    sid       = "DenyPlaintextTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/trail/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit.json
}

resource "aws_cloudtrail" "account" {
  name                          = "${var.name_prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.audit.id
  s3_key_prefix                 = "trail"
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  tags = { Name = "${var.name_prefix}-trail" }

  depends_on = [aws_s3_bucket_policy.audit]
}

# Cost guardrail (issue #21): "cheap by design" as an alarm, not a claim.
# A monthly cost budget pages the same SNS topic as the intrusion alarms
# on actual breach (>=100% spent) and on forecasted breach (>=100%
# projected). The Budgets API is free; no Cost Explorer dependency.
# Moto note: the local job plans the whole stack but applies only
# module.compute, so this resource stays plan-only against the mock.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }
}
