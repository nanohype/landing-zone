variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "tenant_config" {
  type = object({
    waf_enabled                = bool
    cognito_enabled            = bool
    bot_control_enabled        = bool
    deletion_protection        = bool
    stage_name                 = string
    logging_level              = string
    waf_rate_limit             = number
    cognito_password_min       = number
    cognito_access_token_hrs   = number
    cognito_refresh_token_days = number
    throttle_rate_limit        = number
    throttle_burst_limit       = number
    throttle_quota_per_month   = number
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
