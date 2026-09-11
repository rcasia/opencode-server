# App bundle bucket (ADR-0011): the deployable behind zero-downtime app
# deploys. user_data fetches compose.yaml + Caddyfile from here at boot;
# deploy-app re-uploads on app/** changes and rolling-restarts via SSM.
# Versioned: rollback = revert commit + push. Contents are reproducible
# from git, so force_destroy is safe.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "app_bundle" {
  bucket        = "${local.name_prefix}-app-bundle-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
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

output "app_bundle_bucket" {
  description = "S3 bucket holding the deployed app bundle (compose.yaml, Caddyfile)"
  value       = aws_s3_bucket.app_bundle.bucket
}
