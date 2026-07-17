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
  description = "List of group-to-permission-set-to-account assignments"
  type = list(object({
    group          = string
    permission_set = string
    account_id     = string
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
