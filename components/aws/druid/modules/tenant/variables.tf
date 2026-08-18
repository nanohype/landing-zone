variable "environment" {
  description = "Environment name"
  type        = string
}

variable "region" {
  description = "AWS region"
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
  description = "Tenant configuration"
  type = object({
    rds_min_acu         = number
    rds_max_acu         = number
    rds_backup_days     = number
    msk_enabled         = bool
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

variable "node_sg_id" {
  description = "EKS node security group ID — the source of every packet a pod sends out of the cluster, and therefore the only thing a datastore's ingress rule can usefully allow."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "force_destroy_buckets" {
  description = "Opt-in, outside development, to empty S3 buckets on destroy and skip Aurora's final snapshot. Development always allows both."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply"
  type        = map(string)
  default     = {}
}
