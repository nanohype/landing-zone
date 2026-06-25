variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for RDS/MSK"
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
