variable "environment" {
  description = "Environment name (dev, staging, production)"
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
