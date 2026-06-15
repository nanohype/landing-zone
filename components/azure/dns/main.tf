locals {
  tags = merge(var.tags, {
    Component = "dns"
    Team      = var.team
  })
}

################################################################################
# Resource Group
################################################################################

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

################################################################################
# Public DNS Zone
################################################################################

resource "azurerm_dns_zone" "this" {
  count = var.create_dns_zone ? 1 : 0

  name                = var.domain_name
  resource_group_name = data.azurerm_resource_group.this.name

  tags = local.tags
}

################################################################################
# Private DNS Zone (internal resolution within VNet)
################################################################################

resource "azurerm_private_dns_zone" "this" {
  count = var.create_dns_zone ? 1 : 0

  name                = "internal.${var.domain_name}"
  resource_group_name = data.azurerm_resource_group.this.name

  tags = local.tags
}
