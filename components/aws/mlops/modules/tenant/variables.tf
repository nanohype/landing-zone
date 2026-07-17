variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "tenant_id" {
  description = "Tenant identifier"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$", var.tenant_id))
    error_message = "tenant_id must be a lowercase RFC-1123 label of at most 24 characters: it is concatenated into S3 bucket (63-char) and IAM role (64-char) names. The account-qualified bucket name <env>-<domain>-<tenant_id>-<account>-<purpose> is the tightest; the exact per-component budget for a full-word environment is enforced by the component-level tenants validation."
  }
}

variable "tenant_config" {
  description = "Tenant MLOps configuration"
  type = object({
    deletion_protection           = bool
    ecr_enabled                   = bool
    point_in_time_recovery        = bool
    datasets_lifecycle_ia_days    = number
    datasets_version_expiry_days  = number
    artifacts_lifecycle_ia_days   = number
    artifacts_version_expiry_days = number
    run_ttl_days                  = number
    deprecated_version_ttl_days   = number
    sqs_visibility_timeout        = number
    sqs_max_receive_count         = number
    sqs_dlq_retention_days        = number
  })
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
