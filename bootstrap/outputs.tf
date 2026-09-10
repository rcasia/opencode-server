output "state_bucket" {
  description = "S3 bucket for terraform state. Copy into backend.hcl."
  value       = aws_s3_bucket.state.bucket
}

output "state_key" {
  description = "State key for the root stack in staging"
  value       = "opencode-server/staging/terraform.tfstate"
}
