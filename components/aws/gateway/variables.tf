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

variable "cluster_sg_id" {
  description = "EKS cluster security group ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "tenants" {
  description = "Map of gateway tenant configurations"
  type = map(object({
    waf_enabled                = optional(bool, true)
    cognito_enabled            = optional(bool, true)
    bot_control_enabled        = optional(bool, true)
    deletion_protection        = optional(bool, true)
    stage_name                 = optional(string, "v1")
    logging_level              = optional(string, "ERROR")
    waf_rate_limit             = optional(number, 2000)
    cognito_password_min       = optional(number, 12)
    cognito_access_token_hrs   = optional(number, 1)
    cognito_refresh_token_days = optional(number, 30)
    throttle_rate_limit        = optional(number, 50)
    throttle_burst_limit       = optional(number, 100)
    throttle_quota_per_month   = optional(number, 500000)
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
