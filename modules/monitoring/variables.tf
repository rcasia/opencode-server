variable "name_prefix" {
  description = "Prefix for resource names and Name tags"
  type        = string
}

variable "alert_email" {
  description = "Email for intrusion alarms. Empty disables the subscription (alarms still exist)."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Public domain for the uptime probe. Empty disables it."
  type        = string
  default     = ""
}

variable "instance_id" {
  description = "EC2 instance ID for the CPU alarm. Empty disables the CPU alarm (fail-open)."
  type        = string
  default     = ""
}
