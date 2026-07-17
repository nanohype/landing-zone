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
    error_message = "tenant_id must be a lowercase RFC-1123 label of at most 24 characters: it is concatenated into S3 bucket (63-char) and IAM role (64-char) names, and a longer id overflows the tightest name (<env>-governance-<tenant_id>-guardrails) once the environment is a full word."
  }
}

variable "tenant_config" {
  description = "Tenant governance configuration"
  type = object({
    deletion_protection    = optional(bool, true)
    object_lock_enabled    = optional(bool, false)
    event_bridge_enabled   = optional(bool, true)
    point_in_time_recovery = optional(bool, true)
    lifecycle_ia_days      = optional(number, 90)
    lifecycle_glacier_days = optional(number, 365)
    archive_retention_days = optional(number, 90)
    cost_ttl_days          = optional(number, 395)
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
