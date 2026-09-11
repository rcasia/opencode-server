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
  description = "EC2 instance ID for the CPU alarm dimensions."
  type        = string
  default     = ""
}

variable "disk_threshold_percent" {
  description = "disk_used_percent on /var/lib/docker that pages the operator."
  type        = number
  default     = 80
}

variable "mem_threshold_percent" {
  description = "mem_used_percent sustained 15 minutes that pages the operator."
  type        = number
  default     = 90
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
