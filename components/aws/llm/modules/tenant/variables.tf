variable "environment" {
  description = "Environment name (development, staging, production). Prefixes every derived tenant resource name."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "account_id" {
  description = "AWS account ID. Embedded into S3 bucket names for global uniqueness."
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
  description = "Per-tenant LLM configuration: deletion-protection, EFS mount options, SQS tuning, DynamoDB TTL/PITR, HuggingFace token toggle, and model-storage lifecycle windows."
  type = object({
    deletion_protection           = bool
    efs_encryption                = bool
    efs_performance_mode          = string
    efs_throughput_mode           = string
    sqs_visibility_timeout        = number
    sqs_retention_days            = number
    sqs_max_receive_count         = number
    dynamodb_ttl_enabled          = bool
    dynamodb_pitr                 = bool
    hf_token_enabled              = bool
    model_version_expiry_days     = number
    incomplete_upload_expiry_days = number
  })
}

variable "vpc_id" {
  description = "VPC ID the tenant's EFS mount targets and private endpoints sit in."
  type        = string
}

variable "private_subnets" {
  description = "Private subnet IDs (multi-AZ) for the tenant's EFS mount targets."
  type        = list(string)
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID used as the ingress source so only pods reach the tenant's data plane."
  type        = string
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
