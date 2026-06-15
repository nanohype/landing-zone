locals {
  resource_group_name = trimsuffix(var.cluster_name, "-aks")
  identity_prefix     = "${var.cluster_name}-wi-druid-${var.tenant_name}"

  # Storage account names are globally unique across all of Azure and capped
  # at 24 chars alphanumeric. Append a subscription hash for uniqueness.
  storage_account_name = substr("${replace("${var.cluster_name}druid${var.tenant_name}", "-", "")}${replace(var.subscription_id, "-", "")}", 0, 24)

  postgres_name    = "${var.cluster_name}-druid-${var.tenant_name}"
  postgres_db_name = "druid"
  postgres_admin   = "druidadmin"
  k8s_namespace    = "druid-${var.tenant_name}"

  tags = merge(var.tags, {
    Component = "druid-catalog"
    Tenant    = var.tenant_name
    Team      = var.team
  })
}

data "azurerm_resource_group" "this" {
  name = local.resource_group_name
}

data "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = local.resource_group_name
}

################################################################################
# Random password for the PostgreSQL admin user
################################################################################

resource "random_password" "postgres_admin" {
  length           = 32
  special          = true
  override_special = "_-"
}

resource "random_password" "druid_admin_user" {
  length           = 24
  special          = true
  override_special = "_-"
}

resource "random_password" "druid_system_user" {
  length           = 24
  special          = true
  override_special = "_-"
}

################################################################################
# PostgreSQL Flexible Server — Druid metadata store
################################################################################

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = local.postgres_name
  resource_group_name           = data.azurerm_resource_group.this.name
  location                      = data.azurerm_resource_group.this.location
  version                       = "17"
  administrator_login           = local.postgres_admin
  administrator_password        = random_password.postgres_admin.result
  delegated_subnet_id           = var.private_subnet_id
  public_network_access_enabled = false
  sku_name                      = var.postgres_sku_name
  storage_mb                    = var.postgres_storage_mb
  zone                          = "1"

  authentication {
    password_auth_enabled = true
  }

  tags = local.tags
}

resource "azurerm_postgresql_flexible_server_database" "druid" {
  name      = local.postgres_db_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

################################################################################
# Storage Account — Druid (deep-storage, index-logs, msq containers)
################################################################################

resource "azurerm_storage_account" "this" {
  name                     = local.storage_account_name
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    delete_retention_policy {
      days = 14
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "deep_storage" {
  name                  = "deep-storage"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "index_logs" {
  name                  = "index-logs"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "msq" {
  name                  = "msq"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

################################################################################
# Workload Identities — Druid component service accounts
#
# Druid's helm chart in aks-gitops creates four ServiceAccounts:
# druid-historical, druid-overlord, druid-broker, druid-kafka-client.
# Each gets its own UAMI scoped to the druid storage account.
################################################################################

module "druid_historical_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-historical"
  resource_group  = local.resource_group_name
  location        = data.azurerm_resource_group.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = local.k8s_namespace
  service_account = "druid-historical"
  scope           = azurerm_storage_account.this.id

  role_assignments = ["Storage Blob Data Contributor"]

  tags = local.tags
}

module "druid_overlord_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-overlord"
  resource_group  = local.resource_group_name
  location        = data.azurerm_resource_group.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = local.k8s_namespace
  service_account = "druid-overlord"
  scope           = azurerm_storage_account.this.id

  role_assignments = ["Storage Blob Data Contributor"]

  tags = local.tags
}

module "druid_broker_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-broker"
  resource_group  = local.resource_group_name
  location        = data.azurerm_resource_group.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = local.k8s_namespace
  service_account = "druid-broker"
  scope           = azurerm_storage_account.this.id

  role_assignments = ["Storage Blob Data Contributor"]

  tags = local.tags
}

module "druid_kafka_client_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-kafka-client"
  resource_group  = local.resource_group_name
  location        = data.azurerm_resource_group.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = local.k8s_namespace
  service_account = "druid-kafka-client"

  tags = local.tags
}

################################################################################
# Key Vault Secrets — Druid credentials
#
# These are read by the Druid chart's ExternalSecret CRs (in aks-gitops
# catalog/druid/chart/templates/externalsecret.yaml). The chart references
# the secret name via the tenant's values.yaml (secrets.metadata, .admin,
# .system) — set those to the secret names produced here.
################################################################################

resource "azurerm_key_vault_secret" "metadata" {
  name         = "druid-${var.tenant_name}-metadata"
  key_vault_id = var.key_vault_id

  # The ExternalSecret in aks-gitops uses property pluck (username, password,
  # host, dbname). KV stores a JSON document matching that shape.
  value = jsonencode({
    username = local.postgres_admin
    password = random_password.postgres_admin.result
    host     = azurerm_postgresql_flexible_server.this.fqdn
    dbname   = local.postgres_db_name
  })

  content_type = "application/json"

  tags = local.tags
}

resource "azurerm_key_vault_secret" "admin" {
  name         = "druid-${var.tenant_name}-admin"
  key_vault_id = var.key_vault_id

  value = jsonencode({
    username = "druid-admin"
    password = random_password.druid_admin_user.result
  })

  content_type = "application/json"

  tags = local.tags
}

resource "azurerm_key_vault_secret" "system" {
  name         = "druid-${var.tenant_name}-system"
  key_vault_id = var.key_vault_id

  value = jsonencode({
    username = "druid-system"
    password = random_password.druid_system_user.result
  })

  content_type = "application/json"

  tags = local.tags
}
