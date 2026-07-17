variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "tenant_id" {
  description = "Tenant identifier"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$", var.tenant_id))
    error_message = "tenant_id must be a lowercase RFC-1123 label of at most 24 characters: it is concatenated into S3 bucket (63-char) and IAM role (64-char) names, and a longer id overflows the tightest name (<env>-<domain>-<tenant_id>-<purpose>) once the environment is a full word."
  }
}

variable "tenant_config" {
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
  type = string
}

variable "private_subnets" {
  type = list(string)
}

variable "cluster_sg_id" {
  type = string
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
