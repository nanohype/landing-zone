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

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
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
  description = "Enable the local vault lock (GOVERNANCE mode — deletable by an explicit override permission, never the irreversible COMPLIANCE door). Recommended for production."
  type        = bool
  default     = false
}

variable "min_retention_days" {
  description = "Minimum retention the local vault lock enforces (governance mode). Ignored when enable_vault_lock is false."
  type        = number
  default     = 1

  validation {
    condition     = var.min_retention_days >= 1
    error_message = "min_retention_days must be at least 1 — AWS Backup Vault Lock's floor."
  }
}

variable "max_retention_days" {
  description = "Maximum retention the local vault lock enforces (governance mode). Ignored when enable_vault_lock is false."
  type        = number
  default     = 365

  validation {
    condition     = var.max_retention_days >= var.min_retention_days
    error_message = "max_retention_days must be greater than or equal to min_retention_days."
  }
}

variable "central_vault_arn" {
  description = <<-EOT
    ARN of the central backup vault (components/aws/shared-backup) every plan rule copies its
    recovery points to. Empty (default) emits no copy action — the shape before central backup
    is stood up. When set, each plan without its own copy_action override copies to this vault
    with the plan's own retention. This is a cross-account value carried to workload leaves as a
    known input, since the owning account's SSM is not readable from here.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.central_vault_arn == "" || can(regex("^arn:aws[a-z-]*:backup:", var.central_vault_arn))
    error_message = "central_vault_arn must be empty or an AWS Backup vault ARN (arn:aws:backup:<region>:<account>:backup-vault:<name>)."
  }
}

variable "restore_testing" {
  description = <<-EOT
    Scheduled AWS Backup restore testing — an untested backup is a belief, not a recovery. When
    enabled, a restore testing plan restores recent recovery points on a schedule and reports,
    with no human initiating it, proving the recovery point is usable. resource_types are the
    AWS Backup protected-resource types to test (the platform backs up Aurora, DynamoDB, EFS,
    S3); each becomes a selection restoring all protected resources of that type via the backup
    role. Disabled by default because a restore test provisions and tears down real resources
    (real, if brief, cost); enable per environment.
  EOT
  type = object({
    enabled                 = optional(bool, false)
    schedule                = optional(string, "cron(0 5 ? * 1 *)")
    start_window_hours      = optional(number, 24)
    selection_window_days   = optional(number, 7)
    validation_window_hours = optional(number, 1)
    resource_types          = optional(list(string), ["Aurora", "DynamoDB"])
  })
  default = {}
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
