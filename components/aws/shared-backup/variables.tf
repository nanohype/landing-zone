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

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring.
# The provider carries the region; this component names no region-qualified resources, so the
# value is not referenced directly. The DR region is expressed by where this leaf is placed.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region — the DR region this central vault is placed in."
  type        = string
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "organization_id" {
  description = <<-EOT
    The AWS Organizations id (o-xxxxxxxxxx) that scopes cross-account copy into this vault.
    Both the vault access policy and the vault CMK policy admit a wildcard principal bounded
    by aws:PrincipalOrgID = this value, so exactly the accounts in this organization — and no
    external account — can copy recovery points into the central vault.
  EOT
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must be an AWS Organizations id of the form o-xxxxxxxxxx (o- followed by 10-32 lowercase alphanumerics)."
  }
}

variable "min_retention_days" {
  description = "Minimum retention the governance-locked vault enforces. A copy job with a shorter lifecycle is rejected. 1 day matches the workload plans' fast-restore tier; raise per environment."
  type        = number
  default     = 1

  validation {
    condition     = var.min_retention_days >= 1
    error_message = "min_retention_days must be at least 1 — AWS Backup Vault Lock's floor."
  }
}

variable "max_retention_days" {
  description = "Maximum retention the governance-locked vault enforces. A copy job with a longer lifecycle is rejected. Bounds how long a recovery point can be pinned in the central vault."
  type        = number
  default     = 365

  validation {
    condition     = var.max_retention_days >= var.min_retention_days
    error_message = "max_retention_days must be greater than or equal to min_retention_days."
  }
}

variable "kms_deletion_window" {
  description = "KMS key deletion window in days"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
