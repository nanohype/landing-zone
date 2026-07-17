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

variable "cluster_name" {
  description = "EKS cluster name (used for naming)"
  type        = string
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "amg_account_access_type" {
  description = "Whether the Grafana workspace has CURRENT_ACCOUNT or ORGANIZATION account access"
  type        = string
  default     = "CURRENT_ACCOUNT"
}

variable "amg_authentication_providers" {
  description = "Grafana auth providers (AWS_SSO, SAML)"
  type        = list(string)
  default     = ["AWS_SSO"]
}

variable "amg_admin_user_ids" {
  description = "IAM Identity Center user IDs to grant Grafana ADMIN role"
  type        = list(string)
  default     = []
}

variable "amg_editor_user_ids" {
  description = "IAM Identity Center user IDs to grant Grafana EDITOR role"
  type        = list(string)
  default     = []
}

variable "amg_viewer_user_ids" {
  description = "IAM Identity Center user IDs to grant Grafana VIEWER role"
  type        = list(string)
  default     = []
}

variable "amp_alert_rules_enabled" {
  description = "Enable alert manager + rule group definitions on the AMP workspace"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
