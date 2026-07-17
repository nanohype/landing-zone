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

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "tenants" {
  description = "Map of governance tenant configurations"
  type = map(object({
    deletion_protection    = optional(bool, true)
    object_lock_enabled    = optional(bool, false)
    event_bridge_enabled   = optional(bool, true)
    point_in_time_recovery = optional(bool, true)
    lifecycle_ia_days      = optional(number, 90)
    lifecycle_glacier_days = optional(number, 365)
    archive_retention_days = optional(number, 90)
    cost_ttl_days          = optional(number, 395)
  }))

  # no-doubled-env: reject a tenant key that repeats the environment token, which
  # would compose into a doubled "<env>-governance-<env>-…" name.
  validation {
    condition     = alltrue([for k in keys(var.tenants) : k != var.environment && !startswith(k, "${var.environment}-")])
    error_message = "a tenant key must not equal or be prefixed with the environment token '${var.environment}-': it composes into a doubled '<env>-governance-<env>…' resource name."
  }

  # bucket-global-uniqueness budget: governance is the tightest tenant namespace —
  # <env>-governance-<tenant>-<account:12>-guardrails against S3's 63-char limit.
  validation {
    condition     = alltrue([for k in keys(var.tenants) : length("${var.environment}-governance-${k}-000000000000-guardrails") <= 63])
    error_message = "a tenant key is too long: '<env>-governance-<tenant>-<account:12>-guardrails' must fit S3's 63-char limit. With environment='${var.environment}' and a 12-char account id, a tenant key has at most ${63 - length(var.environment) - 36} chars."
  }
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
