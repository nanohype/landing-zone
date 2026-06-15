variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL for workload identity federation"
  type        = string
}

variable "team" {
  description = "Team name for resource tagging"
  type        = string
}

variable "tags" {
  description = "Org-wide tags injected by the root config (azurerm has no provider default_tags)."
  type        = map(string)
  default     = {}
}
