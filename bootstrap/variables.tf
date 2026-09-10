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
  default     = "staging"
}
