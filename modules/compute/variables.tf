variable "name_prefix" {
  description = "Prefix for resource names and Name tags"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the server"
  type        = string
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
  description = "AWS region (used to fetch the opencode password from SSM)"
  type        = string
}

variable "opencode_password_parameter" {
  description = "SSM SecureString parameter holding OPENCODE_SERVER_PASSWORD"
  type        = string
  default     = "/opencode/server-password"
}

variable "domain_name" {
  description = "Public domain for opencode web (Caddy TLS). Empty skips Caddy config."
  type        = string
  default     = ""
}
