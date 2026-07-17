variable "environment" {
  description = "Environment name (development, staging, production). Prefixes every derived tenant resource name."
  type        = string
}

variable "region" {
  description = "AWS region."
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
  description = "Per-tenant API-gateway configuration: WAF/Cognito/bot-control toggles, deletion protection, stage name, logging level, and the WAF-rate-limit / throttle / Cognito-token knobs."
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
