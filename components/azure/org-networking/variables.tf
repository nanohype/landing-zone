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

variable "enable_virtual_wan" {
  description = "Whether to create an Azure Virtual WAN"
  type        = bool
  default     = true
}

variable "virtual_wan_name" {
  description = "Name of the Azure Virtual WAN"
  type        = string
  default     = "org-virtual-wan"
}

variable "virtual_hub_name" {
  description = "Name of the Azure Virtual Hub"
  type        = string
  default     = "org-virtual-hub"
}

variable "hub_address_prefix" {
  description = "Address prefix for the Virtual Hub (e.g. 10.0.0.0/24)"
  type        = string
  default     = "10.0.0.0/24"
}

variable "spoke_vnets" {
  description = "Map of spoke virtual networks to connect to the hub"
  type = map(object({
    vnet_id                   = string
    internet_security_enabled = optional(bool, true)
  }))
  default = {}
}

variable "private_dns_zones" {
  description = "Map of private DNS zones to create with optional VNet links"
  type = map(object({
    domain_name = string
    vnet_links = optional(list(object({
      name                 = string
      virtual_network_id   = string
      registration_enabled = optional(bool, false)
    })), [])
  }))
  default = {}
}

variable "tags" {
  description = "Org-wide tags injected by the root config (azurerm has no provider default_tags)."
  type        = map(string)
  default     = {}
}
