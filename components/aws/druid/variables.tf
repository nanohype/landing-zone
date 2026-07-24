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

variable "network" {
  description = <<-EOT
    VPC placement facts from the network component's `network` output, taken as one object
    rather than as loose vpc_id / subnet scalars that could disagree. The network producer
    guarantees the private subnets reside in vpc_id (built there in create mode, asserted
    there in adopt mode), so consuming the object whole is what makes the triple correct by
    construction. ownership_mode is create when this account owns the VPC and adopt when it
    participates in a VPC owned by another account (a RAM-shared VPC); in adopt mode druid
    mints its own Aurora/MSK security groups in the shared VPC — the AWS-supported participant
    pattern — and network-preflight.tf asserts placement at plan.
  EOT
  type = object({
    vpc_id             = string
    ownership_mode     = string
    private_subnet_ids = list(string)
    private_subnet_azs = list(string)
  })

  validation {
    condition     = contains(["create", "adopt"], var.network.ownership_mode)
    error_message = "network.ownership_mode must be \"create\" or \"adopt\"."
  }

  validation {
    condition     = length(var.network.private_subnet_ids) > 0
    error_message = "network.private_subnet_ids must be non-empty — Aurora and MSK are placed in these subnets."
  }
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
  description = "Map of Druid tenant configurations"
  type = map(object({
    rds_min_acu         = optional(number, 0.5)
    rds_max_acu         = optional(number, 8)
    rds_backup_days     = optional(number, 7)
    msk_enabled         = optional(bool, true)
    secret_rotation     = optional(bool, true)
    deletion_protection = optional(bool, true)
    index_logs_expiry   = optional(number, 30)
    msq_expiry          = optional(number, 1)
  }))

  # no-doubled-env: reject a tenant key that repeats the environment token, which
  # would compose into a doubled "<env>-druid-<env>-…" name.
  validation {
    condition     = alltrue([for k in keys(var.tenants) : k != var.environment && !startswith(k, "${var.environment}-")])
    error_message = "a tenant key must not equal or be prefixed with the environment token '${var.environment}-': it composes into a doubled '<env>-druid-<env>…' resource name."
  }

  # bucket-global-uniqueness budget: the tightest S3 name is
  # <env>-druid-<tenant>-<account:12>-deepstorage; S3 caps names at 63 chars.
  validation {
    condition     = alltrue([for k in keys(var.tenants) : length("${var.environment}-druid-${k}-000000000000-deepstorage") <= 63])
    error_message = "a tenant key is too long: '<env>-druid-<tenant>-<account:12>-deepstorage' must fit S3's 63-char limit. With environment='${var.environment}' and a 12-char account id, a tenant key has at most ${63 - length(var.environment) - 32} chars."
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
