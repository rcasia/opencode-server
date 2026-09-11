output "state_bucket" {
  description = "S3 bucket for terraform state. Set as TF_STATE_BUCKET variable."
  value       = aws_s3_bucket.state.bucket
}

output "state_key" {
  description = "State key for the root stack in prod"
  value       = "opencode-server/prod/terraform.tfstate"
}

output "deploy_role_arn" {
  description = "Deploy role for GitHub OIDC. Set as AWS_ROLE_ARN secret."
  value       = aws_iam_role.deploy.arn
}
