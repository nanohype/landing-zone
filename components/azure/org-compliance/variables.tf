variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "team" {
  description = "Team name for resource tagging"
  type        = string
}

variable "enable_activity_log" {
  description = "Enable Activity Log diagnostic settings"
  type        = bool
  default     = true
}

variable "resource_group_name" {
  description = "Name of the resource group for compliance resources"
  type        = string
  default     = "org-compliance-rg"
}

variable "location" {
  description = "Azure region for resource deployment"
  type        = string
}

variable "workspace_name" {
  description = "Name of the Log Analytics workspace for central auditing"
  type        = string
  default     = "org-audit-workspace"
}

variable "log_retention_days" {
  description = "Number of days to retain logs in Log Analytics"
  type        = number
  default     = 365
}

variable "storage_account_name" {
  description = "Name of the storage account for audit log archival"
  type        = string
}

variable "archive_retention_days" {
  description = "Number of days to retain archived audit logs before deletion"
  type        = number
  default     = 2555
}

variable "enable_cis_benchmark" {
  description = "Enable CIS Microsoft Azure Foundations Benchmark policy assignment"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Org-wide tags injected by the root config (azurerm has no provider default_tags)."
  type        = map(string)
  default     = {}
}
