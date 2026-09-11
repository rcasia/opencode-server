variable "name_prefix" {
  description = "Prefix for resource names and Name tags"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the single public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "AZ for the public subnet (single AZ, no NAT to stay cheap)"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed for SSH. Empty means no port-22 ingress (SSM-only). With ssh_public_key set, must be an explicit /32."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key. Empty means SSM-only: no port-22 ingress is created."
  type        = string
  default     = ""
  sensitive   = true
}
