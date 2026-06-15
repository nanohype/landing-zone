variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD tenant ID (for Managed Grafana SSO)"
  type        = string
}

variable "cluster_name" {
  description = "Name of the AKS cluster (used to derive RG and naming)"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL for workload identity federation (used by grafana-agent remote-write identity)"
  type        = string
}

variable "team" {
  description = "Team name for resource tagging"
  type        = string
}

variable "grafana_admin_object_ids" {
  description = "List of Azure AD object IDs to grant Grafana Admin on the managed Grafana instance"
  type        = list(string)
  default     = []
}

variable "grafana_editor_object_ids" {
  description = "List of Azure AD object IDs to grant Grafana Editor"
  type        = list(string)
  default     = []
}

variable "grafana_viewer_object_ids" {
  description = "List of Azure AD object IDs to grant Grafana Viewer"
  type        = list(string)
  default     = []
}

variable "grafana_sku" {
  description = "Azure Managed Grafana SKU (Standard or Essential)"
  type        = string
  default     = "Standard"
}

variable "grafana_zone_redundancy_enabled" {
  description = "Enable zone redundancy for Managed Grafana"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Org-wide tags injected by the root config (azurerm has no provider default_tags)."
  type        = map(string)
  default     = {}
}
