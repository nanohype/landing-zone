variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the AKS cluster (used to derive resource group + identity prefix)"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL for workload identity federation"
  type        = string
}

variable "tenant_name" {
  description = "Druid tenant name (e.g. analytics, marketing). One druid-catalog deployment per tenant."
  type        = string
}

variable "key_vault_id" {
  description = "ID of the Azure Key Vault where Druid credential secrets are stored"
  type        = string
}

variable "private_subnet_id" {
  description = "ID of a private subnet for the PostgreSQL Flexible Server delegation"
  type        = string
}

variable "team" {
  description = "Team name for resource tagging"
  type        = string
}

variable "postgres_sku_name" {
  description = "SKU name for the PostgreSQL Flexible Server"
  type        = string
  default     = "B_Standard_B2ms"
}

variable "postgres_storage_mb" {
  description = "Storage size in MB for the PostgreSQL Flexible Server"
  type        = number
  default     = 32768
}

variable "tags" {
  description = "Org-wide tags injected by the root config (azurerm has no provider default_tags)."
  type        = map(string)
  default     = {}
}
