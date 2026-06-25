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
