variable "aws_region" {
  description = "AWS region for the state bucket"
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Project name used for tagging and naming"
  type        = string
  default     = "opencode"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

variable "deploy_subject" {
  description = "Exact OIDC sub allowed to assume the deploy role (EMU immutable form, with numeric IDs)"
  type        = string
  default     = "repo:rcasia@31012661/opencode-server@1364478756:environment:prod"
}

variable "deploy_ref" {
  description = "OIDC ref claim allowed to assume the deploy role"
  type        = string
  default     = "refs/heads/main"
}
