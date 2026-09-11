
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