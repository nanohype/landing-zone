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

variable "kms_deletion_window" {
  description = "KMS key deletion window in days"
  type        = number
  default     = 30
}

variable "enable_vault_lock" {
  description = "Enable vault lock for immutable backups (recommended for production)"
  type        = bool
  default     = false
}

variable "notification_emails" {
  description = "Email addresses for backup failure notifications"
  type        = list(string)
  default     = []
}

variable "backup_plans" {
  description = "Map of backup plan configurations"
  type = map(object({
    schedule           = string
    retention_days     = number
    cold_storage_after = optional(number)
    copy_action = optional(object({
      destination_vault_arn = string
      retention_days        = number
    }))
  }))
  default = {
    daily = {
      schedule       = "cron(0 3 * * ? *)"
      retention_days = 7
    }
  }
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
