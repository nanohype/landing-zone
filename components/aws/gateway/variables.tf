variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string

  # Format contract, not a closed enum: the platform legitimately uses development, staging,
  # production, prod, hub, org, management, and per-workload derivations, so pinning a
  # fixed set would reject valid environments. This still catches empty/uppercase/typo'd
  # values before they flow into resource names, tags, and SSM paths.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
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
