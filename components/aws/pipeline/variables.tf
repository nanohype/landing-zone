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

variable "private_subnet_ids" {
  description = "Private subnet IDs"
  type        = list(string)
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
  description = "Map of tenant configurations for pipeline infrastructure"
  type = map(object({
    deletion_protection           = optional(bool, true)
    msk_enabled                   = optional(bool, true)
    batch_enabled                 = optional(bool, true)
    schema_registry_enabled       = optional(bool, true)
    batch_max_vcpus               = optional(number, 64)
    batch_type                    = optional(string, "FARGATE")
    raw_lifecycle_ia_days         = optional(number, 90)
    raw_lifecycle_expiry_days     = optional(number, 730)
    staging_lifecycle_expiry_days = optional(number, 180)
    curated_version_expiry_days   = optional(number, 730)
  }))

  # no-doubled-env: reject a tenant key that repeats the environment token, which
  # would compose into a doubled "<env>-pipeline-<env>-…" name.
  validation {
    condition     = alltrue([for k in keys(var.tenants) : k != var.environment && !startswith(k, "${var.environment}-")])
    error_message = "a tenant key must not equal or be prefixed with the environment token '${var.environment}-': it composes into a doubled '<env>-pipeline-<env>…' resource name."
  }

  # bucket-global-uniqueness budget: the tightest S3 name is
  # <env>-pipeline-<tenant>-<account:12>-staging; S3 caps names at 63 chars.
  validation {
    condition     = alltrue([for k in keys(var.tenants) : length("${var.environment}-pipeline-${k}-000000000000-staging") <= 63])
    error_message = "a tenant key is too long: '<env>-pipeline-<tenant>-<account:12>-<suffix>' must fit S3's 63-char limit. With environment='${var.environment}' and a 12-char account id, a tenant key has at most ${63 - length(var.environment) - 31} chars."
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
