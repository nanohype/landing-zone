variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string

  # Format contract, not a closed enum: the platform legitimately uses development, staging,
  # production, prod, hub, org, management, and per-workload derivations, so pinning a
  # fixed set would reject valid environments. This still catches empty/uppercase/typo'd
  # values before they flow into resource names, tags, and SSM paths.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "trusted_account_ids" {
  description = "AWS account IDs allowed to assume the break-glass role"
  type        = list(string)
}

variable "notification_emails" {
  description = "Email addresses for break-glass usage notifications"
  type        = list(string)
  default     = []
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds for break-glass role"
  type        = number
  default     = 3600
}

variable "enable_permissions_boundary" {
  description = "Enable permissions boundary on break-glass role"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
