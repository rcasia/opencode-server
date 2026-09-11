# App bundle bucket (ADR-0011, ADR-0015): the deployable behind zero-downtime
# app deploys. user_data fetches compose.yaml + Caddyfile + switch.sh from
# here at boot; deploy-app re-uploads on app/** changes and switches colors
# via SSM. Versioned: rollback = revert commit + push. Contents are
# reproducible from git, so force_destroy is safe.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "app_bundle" {
  bucket        = "${local.name_prefix}-app-bundle-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  # Moto's S3 mock drops tags on create, so every plan sees tag drift.
  # Real S3 returns them; this only bites the mock idempotence check.
  lifecycle {
    ignore_changes = [tags_all]
  }
}

resource "aws_s3_bucket_versioning" "app_bundle" {
  bucket = aws_s3_bucket.app_bundle.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_bundle" {
  bucket = aws_s3_bucket.app_bundle.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "app_bundle" {
  bucket                  = aws_s3_bucket.app_bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Access-log target for the bundle bucket: SSE + PAB, 90-day expiry.
# Named under the app-bundle prefix so the existing deploy data policy
# pattern (`app-bundle-*`) already scopes it.
resource "aws_s3_bucket" "app_bundle_logs" {
  bucket = "${local.name_prefix}-app-bundle-logs-${data.aws_caller_identity.current.account_id}"

  tags = { Name = "${local.name_prefix}-app-bundle-logs" }

  lifecycle {
    ignore_changes = [tags_all]
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_bundle_logs" {
  bucket = aws_s3_bucket.app_bundle_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "app_bundle_logs" {
  bucket                  = aws_s3_bucket.app_bundle_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "app_bundle_logs" {
  bucket = aws_s3_bucket.app_bundle_logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    # Empty filter = whole bucket (provider warns without one).
    filter {}

    expiration {
      days = 90
    }
  }
}

# Lets S3 server-access logging write into the log bucket. Policy-based
# delivery (PAB-compatible) instead of the log-delivery-write ACL.
data "aws_iam_policy_document" "app_bundle_logs_delivery" {
  statement {
    sid       = "S3ServerAccessLogsDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.app_bundle_logs.arn}/app-bundle/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.app_bundle.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "app_bundle_logs" {
  bucket = aws_s3_bucket.app_bundle_logs.id
  policy = data.aws_iam_policy_document.app_bundle_logs_delivery.json
}

resource "aws_s3_bucket_logging" "app_bundle" {
  bucket        = aws_s3_bucket.app_bundle.id
  target_bucket = aws_s3_bucket.app_bundle_logs.id
  target_prefix = "app-bundle/"
}

# TLS-only guard on the bundle bucket: denies plaintext HTTP. There is
# deliberately NO unencrypted-put deny: S3/CloudTrail service writers do
# not send the SSE header, so StringNotEquals would deny log delivery;
# the bucket default (AES256) already encrypts everything at rest.
data "aws_iam_policy_document" "app_bundle_tls_only" {
  statement {
    sid       = "DenyPlaintextTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.app_bundle.arn, "${aws_s3_bucket.app_bundle.arn}/*"]

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
}

resource "aws_s3_bucket_policy" "app_bundle" {
  bucket = aws_s3_bucket.app_bundle.id
  policy = data.aws_iam_policy_document.app_bundle_tls_only.json
}

# Bundle versions are reproducible from git: expire noncurrent versions
# after 45 days.
resource "aws_s3_bucket_lifecycle_configuration" "app_bundle" {
  bucket = aws_s3_bucket.app_bundle.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # Empty filter = whole bucket (provider warns without one).
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 45
    }
  }
}

output "app_bundle_bucket" {
  description = "S3 bucket holding the deployed app bundle (compose.yaml, Caddyfile, switch.sh)"
  value       = aws_s3_bucket.app_bundle.bucket
}
