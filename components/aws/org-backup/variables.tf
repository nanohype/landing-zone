variable "environment" {
  description = "Environment name"
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

variable "enable_cross_account_backup" {
  description = "Enable org-wide cross-account backup (aws_backup_global_settings). The prerequisite for a workload account copying recovery points into the central backup account's vault."
  type        = bool
  default     = true
}

variable "register_delegated_admin" {
  description = "Register a delegated administrator for AWS Backup, so the backup account administers backup centrally instead of the management account."
  type        = bool
  default     = false
}

variable "delegated_admin_account_id" {
  description = "The account to register as the AWS Backup delegated administrator (the dedicated backup account). Required when register_delegated_admin is true."
  type        = string
  default     = ""

  validation {
    condition     = !var.register_delegated_admin || can(regex("^[0-9]{12}$", var.delegated_admin_account_id))
    error_message = "delegated_admin_account_id must be a 12-digit account id when register_delegated_admin is true."
  }
}

variable "target_ids" {
  description = "Organization root, OU, or account IDs to attach the backup policy to. Attach at the root or a parent OU so every member account inherits the floor."
  type        = list(string)
  default     = []
}

variable "backup_policy" {
  description = <<-EOT
    The org backup floor, generated into the Organizations BACKUP_POLICY document shape. It
    selects resources by the BackupPolicy tag (tag_key / tag_values), backs them up on the
    schedule into each member account's target vault, and — when copy_to_central_vault_arn is
    set — copies each recovery point to the central backup account's vault. iam_role_arn uses
    the $account variable so it resolves to a role in each member account. target_vault_name
    defaults to "Default" so the floor works in an account that never deployed its own backup
    component. cold_storage_after_days = 0 leaves cold-storage transition unset.
  EOT
  type = object({
    plan_name                 = optional(string, "org-baseline")
    rule_name                 = optional(string, "daily")
    regions                   = optional(list(string), ["us-west-2"])
    schedule                  = optional(string, "cron(0 5 ? * * *)")
    start_window_minutes      = optional(number, 60)
    target_vault_name         = optional(string, "Default")
    delete_after_days         = optional(number, 35)
    cold_storage_after_days   = optional(number, 0)
    iam_role_arn              = optional(string, "arn:aws:iam::$account:role/service-role/AWSBackupDefaultServiceRole")
    tag_key                   = optional(string, "BackupPolicy")
    tag_values                = optional(list(string), ["daily"])
    copy_to_central_vault_arn = optional(string, "")
    copy_delete_after_days    = optional(number, 35)
  })
  default = {}

  validation {
    condition     = length(var.backup_policy.regions) > 0
    error_message = "backup_policy.regions must name at least one region for AWS Backup to search."
  }

  validation {
    condition     = var.backup_policy.cold_storage_after_days == 0 || var.backup_policy.delete_after_days >= var.backup_policy.cold_storage_after_days + 90
    error_message = "backup_policy.delete_after_days must be at least cold_storage_after_days + 90 — AWS Backup requires a recovery point to spend 90 days in cold storage before deletion."
  }
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
