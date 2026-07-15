variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string

  # Format contract, not a closed enum: the platform legitimately uses dev, staging,
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
  description = "Map of MLOps tenant configurations"
  type = map(object({
    deletion_protection           = optional(bool, true)
    ecr_enabled                   = optional(bool, true)
    point_in_time_recovery        = optional(bool, true)
    datasets_lifecycle_ia_days    = optional(number, 90)
    datasets_version_expiry_days  = optional(number, 730)
    artifacts_lifecycle_ia_days   = optional(number, 90)
    artifacts_version_expiry_days = optional(number, 730)
    run_ttl_days                  = optional(number, 395)
    deprecated_version_ttl_days   = optional(number, 395)
    sqs_visibility_timeout        = optional(number, 900)
    sqs_max_receive_count         = optional(number, 3)
    sqs_dlq_retention_days        = optional(number, 14)
  }))
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
