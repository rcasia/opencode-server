variable "name_prefix" {
  description = "Prefix for resource names and Name tags"
  type        = string
}

variable "alert_email" {
  description = "Email for intrusion alarms. Empty disables the subscription (alarms still exist)."
  type        = string
  default     = ""
}
