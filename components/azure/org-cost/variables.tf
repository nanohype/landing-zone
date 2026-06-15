variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "team" {
  description = "Team name for resource tagging"
  type        = string
}

variable "enable_cost_export" {
  description = "Enable scheduled Cost Management exports"
  type        = bool
  default     = true
}

variable "resource_group_name" {
  description = "Name of the resource group for cost management resources"
  type        = string
  default     = "org-cost-rg"
}

variable "location" {
  description = "Azure region for resource deployment"
  type        = string
}

variable "budget_limit" {
  description = "Monthly budget limit in the billing currency"
  type        = number
}

variable "budget_start_date" {
  description = "Start date of the budget period in RFC3339 format (e.g. 2026-01-01T00:00:00Z)"
  type        = string
}

variable "budget_alert_thresholds" {
  description = "List of percentage thresholds for budget alerts"
  type        = list(number)
  default     = [50, 75, 90, 100]
}

variable "budget_alert_emails" {
  description = "List of email addresses for budget alert notifications"
  type        = list(string)
}

variable "export_storage_account_name" {
  description = "Name of the storage account for cost export data"
  type        = string
  default     = ""
}

variable "export_start_date" {
  description = "Start date for recurring cost exports in RFC3339 format"
  type        = string
  default     = ""
}

variable "export_end_date" {
  description = "End date for recurring cost exports in RFC3339 format"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Org-wide tags injected by the root config (azurerm has no provider default_tags)."
  type        = map(string)
  default     = {}
}
