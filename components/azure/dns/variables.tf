variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
}

variable "team" {
  description = "Team name for resource tagging"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the DNS zone"
  type        = string
}

variable "create_dns_zone" {
  description = "Whether to create a new DNS zone"
  type        = bool
  default     = true
}

variable "enable_dnssec" {
  description = "Enable DNSSEC for the DNS zone"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Org-wide tags injected by the root config (azurerm has no provider default_tags)."
  type        = map(string)
  default     = {}
}
