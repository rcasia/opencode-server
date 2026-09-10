terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }

  # S3 backend, completed via backend.hcl (see backend.hcl.example).
  # Fill backend.hcl after running bootstrap. CI and pre-commit
  # init with -backend=false, so no bucket is needed there.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  # LocalStack mode: dummy creds + skip all remote validation + per-service endpoints.
  access_key = var.aws_endpoint_url != "" ? "test" : null
  secret_key = var.aws_endpoint_url != "" ? "test" : null

  skip_credentials_validation = var.aws_endpoint_url != ""
  skip_metadata_api_check     = var.aws_endpoint_url != ""
  skip_region_validation      = var.aws_endpoint_url != ""
  skip_requesting_account_id  = var.aws_endpoint_url != ""

  s3_use_path_style = var.aws_endpoint_url != ""

  dynamic "endpoints" {
    for_each = var.aws_endpoint_url != "" ? [var.aws_endpoint_url] : []
    content {
      ec2 = endpoints.value
      iam = endpoints.value
      sts = endpoints.value
      s3  = endpoints.value
    }
  }

  default_tags {
    tags = local.common_tags
  }
}
