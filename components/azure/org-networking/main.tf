locals {
  tags = merge(var.tags, {
    Component = "org-networking"
    Team      = var.team
  })
}

################################################################################
# Virtual WAN
################################################################################

resource "azurerm_virtual_wan" "this" {
  count = var.enable_virtual_wan ? 1 : 0

  name                           = var.virtual_wan_name
  resource_group_name            = var.resource_group_name
  location                       = var.location
  allow_branch_to_branch_traffic = true
  type                           = "Standard"

  tags = merge(local.tags, { Name = var.virtual_wan_name })
}

################################################################################
# Virtual Hub
################################################################################

resource "azurerm_virtual_hub" "this" {
  count = var.enable_virtual_wan ? 1 : 0

  name                = var.virtual_hub_name
  resource_group_name = var.resource_group_name
  location            = var.location
  virtual_wan_id      = azurerm_virtual_wan.this[0].id
  address_prefix      = var.hub_address_prefix
  sku                 = "Standard"

  tags = merge(local.tags, { Name = var.virtual_hub_name })
}

################################################################################
# Hub Virtual Network Connections (Spoke Peering)
################################################################################

resource "azurerm_virtual_hub_connection" "spokes" {
  for_each = var.enable_virtual_wan ? var.spoke_vnets : {}

  name                      = "hub-to-${each.key}"
  virtual_hub_id            = azurerm_virtual_hub.this[0].id
  remote_virtual_network_id = each.value.vnet_id

  internet_security_enabled = each.value.internet_security_enabled
}

################################################################################
# Private DNS Zones
################################################################################

resource "azurerm_private_dns_zone" "this" {
  for_each = var.private_dns_zones

  name                = each.value.domain_name
  resource_group_name = var.resource_group_name

  tags = merge(local.tags, { Name = each.key })
}

################################################################################
# Private DNS Zone — Virtual Network Links
################################################################################

locals {
  # Flatten dns_zone -> vnet_links: {zone_key}-{link_name} => {zone_key, link_name, vnet_id, registration}
  dns_vnet_links = flatten([
    for zone_key, zone in var.private_dns_zones : [
      for link in zone.vnet_links : {
        key                  = "${zone_key}-${link.name}"
        zone_key             = zone_key
        link_name            = link.name
        virtual_network_id   = link.virtual_network_id
        registration_enabled = link.registration_enabled
      }
    ]
  ])
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = { for l in local.dns_vnet_links : l.key => l }

  name                  = each.value.link_name
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.zone_key].name
  virtual_network_id    = each.value.virtual_network_id
  registration_enabled  = each.value.registration_enabled

  tags = local.tags
}
