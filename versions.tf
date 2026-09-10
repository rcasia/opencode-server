terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # S3 backend, completed via backend.hcl (see backend.hcl.example).
  # Fill backend.hcl after running bootstrap. CI and pre-commit
  # init with -backend=false, so no bucket is needed there.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
