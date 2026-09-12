variable "aws_endpoint_url" {
  description = "Endpoint URL override for fully local deploys (LocalStack). Empty means real AWS."
  type        = string
  default     = ""
}

variable "ami_id" {
  description = "Override AMI lookup. Required for LocalStack, which has no AL2023 images."
  type        = string
  default     = ""
}

variable "host_replace_trigger" {
  description = "Flip to a new value (e.g. timestamp) to force host replacement alongside an AMI pin. AMI drift from the lookup never replaces on its own (issue #43)."
  type        = string
  default     = ""
}

variable "enable_data_snapshots" {
  description = "Manage the DLM daily-snapshot policy. False only for the Moto mock (issue #46)."
  type        = bool
  default     = true
}

variable "availability_zone" {
  description = "Override AZ lookup. Useful for LocalStack, whose AZs are mocked."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region for the coding server"
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
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod", "local"], var.environment)
    error_message = "Environment must be dev, staging, prod, or local."
  }
}

variable "instance_type" {
  description = "EC2 instance type for agentic coding"
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed for SSH. Empty disables SSH ingress (SSM-only). With ssh_public_key set, must be an explicit /32, e.g. 1.2.3.4/32."
  type        = string
  default     = ""

  validation {
    condition     = var.allowed_ssh_cidr == "" || (can(cidrhost(var.allowed_ssh_cidr, 0)) && can(regex("/32$", var.allowed_ssh_cidr)))
    error_message = "allowed_ssh_cidr must be empty (SSM-only, no SSH ingress) or an explicit /32 CIDR, e.g. 1.2.3.4/32. Never 0.0.0.0/0."
  }
}

variable "ssh_public_key" {
  description = "Optional SSH public key for ec2-user. If empty, use SSM Session Manager."
  type        = string
  default     = ""
  sensitive   = true
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "opencode_password_parameter" {
  description = "SSM SecureString parameter holding the opencode web password"
  type        = string
  default     = "/opencode/server-password"
}

variable "github_oauth_client_id" {
  description = "Public client ID of the GitHub OAuth App used for web SSO (secret lives in SSM)"
  type        = string
  default     = ""
}

variable "github_oauth_user" {
  description = "Single GitHub username allowed through the SSO gate (oauth2-proxy --github-user)"
  type        = string
  default     = ""
}

variable "github_oauth_secret_parameter" {
  description = "SSM SecureString parameter holding the GitHub OAuth App client secret"
  type        = string
  default     = "/opencode/github-oauth-secret"
}

variable "oauth_cookie_secret_parameter" {
  description = "SSM SecureString parameter holding the oauth2-proxy cookie secret (32-byte base64url)"
  type        = string
  default     = "/opencode/oauth-cookie-secret"
}

variable "provider_api_key_parameters" {
  description = "Map of OpenCode env var names to SSM SecureString parameter names. Empty values disable that provider."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for env_name, parameter_name in var.provider_api_key_parameters :
      can(regex("^[A-Z][A-Z0-9_]*$", env_name)) &&
      (parameter_name == "" || can(regex("^/[A-Za-z0-9._/-]+$", parameter_name)))
    ])
    error_message = "Provider env names must be uppercase environment-variable names and SSM parameter names must be empty or slash-prefixed."
  }
}

variable "alert_email" {
  description = "Email for intrusion alarms. Empty disables the email subscription (deploy-prod warns, never fails)."
  type        = string
  default     = ""
}

variable "monthly_budget_limit_usd" {
  description = "Monthly AWS cost budget in USD that pages the operator on actual or forecasted breach."
  type        = string
  default     = "25"

  validation {
    condition     = can(tonumber(var.monthly_budget_limit_usd)) && tonumber(var.monthly_budget_limit_usd) > 0
    error_message = "monthly_budget_limit_usd must be a positive number, e.g. \"25\"."
  }
}

variable "deployed_version" {
  description = "Version ref stamped on resources (commit SHA from the pipeline, 'unreleased' locally)"
  type        = string
  default     = "unreleased"
}

variable "allow_full_destroy" {
  description = "Allow confirmed pipeline rebuilds to empty and delete stateful S3 buckets"
  type        = bool
  default     = false
}

variable "git_user_name" {
  description = "git identity for commits made on the server"
  type        = string
  default     = ""
}

variable "git_user_email" {
  description = "git email for commits made on the server"
  type        = string
  default     = ""
}

variable "github_token_parameter" {
  description = "SSM SecureString parameter holding a GitHub PAT (repo contents scope) for git auth"
  type        = string
  default     = "/opencode/github-token"
}

variable "domain_name" {
  description = "Public domain for opencode web (Caddy automatic TLS). Empty skips Caddy config."
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^[a-z0-9.-]+$", var.domain_name))
    error_message = "domain_name must be empty or a hostname only, e.g. code.example.com. Do not include https://, http://, a path, or a trailing slash."
  }
}
