variable "environment" {
  description = "Environment name"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
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
  description = "Tenant configuration"
  type = object({
    rds_min_acu         = number
    rds_max_acu         = number
    rds_backup_days     = number
    msk_enabled         = bool
    secret_rotation     = bool
    deletion_protection = bool
    index_logs_expiry   = number
    msq_expiry          = number
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
