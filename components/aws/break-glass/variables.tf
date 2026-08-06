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

variable "trusted_account_ids" {
  description = <<-EOT
    AWS account IDs allowed to assume the break-glass role. Every entry becomes
    an `arn:<partition>:iam::<id>:root` principal on the role's trust policy,
    MFA-gated.

    No default, and both an empty list and the documented management-account
    placeholder are refused, because either produces the same outcome: an
    AdministratorAccess role that nobody can assume, on the one control whose
    entire purpose is to work when everything else does not. A role that reads
    as configured and is not is worse than an absent one — the absence is at
    least visible before the emergency.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.trusted_account_ids) > 0
    error_message = "trusted_account_ids is empty, so this break-glass role would trust nobody and be assumable by nobody. Name the account that holds your emergency operators — break-glass exists to survive THIS account's IAM being broken, so a principal inside it cannot serve."
  }

  validation {
    condition     = !contains(var.trusted_account_ids, "123456789012")
    error_message = "trusted_account_ids still carries 123456789012, the placeholder for a management account that has not been provisioned. AWS would accept a trust policy naming it or reject it outright, and either way nobody can assume the role. Replace it with the real account id — see the component README."
  }
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
