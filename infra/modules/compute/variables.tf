variable "name_prefix" {
  description = "Prefix for resource names and Name tags"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the instance"
  type        = string
}

variable "host_replace_trigger" {
  description = "Change to force host replacement (AMI rotation). AMI lookup drift alone never replaces (issue #43)."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "subnet_id" {
  description = "Subnet ID for the instance"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for the instance"
  type        = string
}

variable "availability_zone" {
  description = "AZ for the instance and the persistent data volume (must match)"
  type        = string
}

variable "data_volume_size" {
  description = "Persistent data disk (Docker state, sessions, certs) in GB"
  type        = number
  default     = 10
}

variable "deployed_version" {
  description = "Version ref stamped on the instance and data disk"
  type        = string
  default     = "unreleased"
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
  description = "SSM SecureString parameter holding a GitHub PAT for git auth"
  type        = string
  default     = "/opencode/github-token"
}

variable "app_bundle_bucket" {
  description = "S3 bucket holding the app bundle (compose.yaml, Caddyfile, switch.sh, opencode.json, host/ stages)"
  type        = string
}

variable "app_bundle_arn" {
  description = "ARN of the app bundle bucket (for the instance read policy)"
  type        = string
}

variable "ssm_sessions_log_group_arn" {
  description = "ARN of the CloudWatch log group receiving SSM session streams (issue #54)"
  type        = string
}

variable "ssh_public_key" {
  description = "Optional SSH public key. If empty, use SSM Session Manager."
  type        = string
  default     = ""
  sensitive   = true
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "aws_region" {
  description = "AWS region (used to fetch secrets from SSM)"
  type        = string
}

variable "opencode_password_parameter" {
  description = "SSM SecureString parameter holding OPENCODE_SERVER_PASSWORD"
  type        = string
  default     = "/opencode/server-password"
}

variable "github_oauth_client_id" {
  description = "Public client ID of the GitHub OAuth App used for web SSO"
  type        = string
  default     = ""
}

variable "github_oauth_user" {
  description = "Single GitHub username allowed through the SSO gate"
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
}

variable "domain_name" {
  description = "Public domain for opencode web (Caddy TLS). Empty skips Caddy config."
  type        = string
  default     = ""
}
