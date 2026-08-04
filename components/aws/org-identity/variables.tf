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

variable "permission_sets" {
  description = "Map of SSO permission sets to create"
  type = map(object({
    description      = string
    session_duration = optional(string, "PT8H")
    managed_policies = optional(list(string), [])
    inline_policy    = optional(string)
    boundary_policy  = optional(string)
  }))
  default = {}
}

variable "groups" {
  description = "Map of Identity Store groups to create"
  type = map(object({
    description = string
  }))
  default = {}
}

variable "account_assignments" {
  description = <<-EOT
    Group-to-permission-set assignments against NAMED accounts.

    The account is named, not identified. Account ids are real identifiers and this is a
    public tree, and a pasted id goes stale in silence the day an account is recreated —
    the assignment still applies, to nothing. The name resolves against the organization
    at apply time, and a name the organization does not have fails the apply saying which.

    For a permission set that should reach every account, use org_wide_assignments
    instead of enumerating them here.
  EOT
  type = list(object({
    group          = string
    permission_set = string
    account_name   = string
  }))
  default = []
}

variable "org_wide_assignments" {
  description = <<-EOT
    Group-to-permission-set assignments that apply to EVERY account in the organization.

    Some roles are org-wide by nature — an auditor that reads one account of several is
    not auditing. Expressing that as "all accounts" rather than as a list is what makes
    adding an account to the organization not silently leave it unaudited, which is the
    failure a list produces and never reports.

    Use account_assignments for anything that should reach some accounts and not others.
  EOT
  type = list(object({
    group          = string
    permission_set = string
  }))
  default = []
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
