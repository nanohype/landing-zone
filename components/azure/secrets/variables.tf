variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
}

variable "location" {
  description = "Azure region for resource deployment"
  type        = string
}

variable "team" {
  description = "Team name for resource tagging"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL for workload identity federation"
  type        = string
}

variable "soft_delete_retention_days" {
  description = "Number of days to retain soft-deleted Key Vault items. Min 7, max 90. For real production use 90 (defense in depth). For personal/portfolio use 7 so destroy/recreate cycles work quickly."
  type        = number
  default     = 90
}

variable "purge_protection_enabled" {
  description = "Whether purge protection is enabled. When TRUE, the vault cannot be force-purged during the soft-delete window — required for compliance but a pain for test envs since destroy/recreate fails until the window expires (90 days max). Set FALSE for personal/portfolio envs."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Org-wide tags injected by the root config (azurerm has no provider default_tags)."
  type        = map(string)
  default     = {}
}
