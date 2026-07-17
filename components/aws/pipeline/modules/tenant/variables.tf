variable "environment" {
  description = "Environment name"
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
  description = "Tenant configuration"
  type = object({
    deletion_protection           = bool
    msk_enabled                   = bool
    batch_enabled                 = bool
    schema_registry_enabled       = bool
    batch_max_vcpus               = number
    batch_type                    = string
    raw_lifecycle_ia_days         = number
    raw_lifecycle_expiry_days     = number
    staging_lifecycle_expiry_days = number
    curated_version_expiry_days   = number
  })
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnets" {
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

variable "tags" {
  description = "Tags to apply"
  type        = map(string)
  default     = {}
}
