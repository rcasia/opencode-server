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
  description = "CIDR allowed for SSH and opencode port. Restrict to your IP, e.g. 1.2.3.4/32"
  type        = string
  default     = "0.0.0.0/0"
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

variable "opencode_port" {
  description = "Port for opencode web / serve"
  type        = number
  default     = 4096
}
