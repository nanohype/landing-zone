data "azurerm_client_config" "current" {}

locals {
  tags = merge(var.tags, {
    Component = "secrets"
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
# Key Vault
################################################################################

resource "azurerm_key_vault" "this" {
  # Key Vault names are globally unique across all Azure tenants and capped at
  # 24 chars. Suffix with a slice of the subscription ID hash so the name
  # doesn't collide with a vault someone else (or a past tenant) already took.
  name                = substr("${replace(var.resource_group_name, "-", "")}secrets${replace(var.subscription_id, "-", "")}", 0, 24)
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  soft_delete_retention_days = var.soft_delete_retention_days
  purge_protection_enabled   = var.purge_protection_enabled
  rbac_authorization_enabled = true

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = local.tags
}

################################################################################
# RBAC — Current Deployer (full admin)
################################################################################

resource "azurerm_role_assignment" "deployer_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

################################################################################
# Workload Identity — External Secrets Operator (Platform)
################################################################################

module "external_secrets_platform_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${var.resource_group_name}-external-secrets-platform"
  resource_group  = data.azurerm_resource_group.this.name
  location        = var.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "external-secrets"
  service_account = "external-secrets"
  scope           = azurerm_key_vault.this.id

  role_assignments = ["Key Vault Secrets User"]

  tags = local.tags
}
