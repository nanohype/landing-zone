locals {
  resource_group_name = trimsuffix(var.cluster_name, "-aks")
  amw_name            = "${var.cluster_name}-amw"
  grafana_name        = "${var.cluster_name}-grafana"
  identity_prefix     = "${var.cluster_name}-wi"

  tags = merge(var.tags, {
    Component = "managed-monitoring"
    Team      = var.team
  })
}

data "azurerm_resource_group" "this" {
  name = local.resource_group_name
}

################################################################################
# Azure Monitor Workspace (managed Prometheus)
################################################################################

resource "azurerm_monitor_workspace" "this" {
  name                = local.amw_name
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location

  tags = local.tags
}

################################################################################
# Data Collection Endpoint + Data Collection Rule
#
# Azure Managed Prometheus does NOT accept remote-write directly against the
# AMW URL. The ingestion path is:
#
#   Prometheus client (grafana-agent)
#     ──> POST <DCE.logs_ingestion_endpoint>/dataCollectionRules/
#              <DCR.immutable_id>/streams/Microsoft-PrometheusMetrics/api/v1/write
#         with `Bearer <AAD token>` from a UAMI that has the
#         `Monitoring Metrics Publisher` role *on the DCR scope*
#
# The DCR routes the `Microsoft-PrometheusMetrics` stream into the AMW
# destination. Without these resources, any remote-write call 404s and
# nothing reaches Prometheus — even if the UAMI and AMW are correctly
# configured.
################################################################################

resource "azurerm_monitor_data_collection_endpoint" "amw" {
  name                = "${var.cluster_name}-amw-dce"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location

  tags = local.tags
}

# `kind` is intentionally omitted on both the DCE and DCR. The "Linux" /
# "Windows" kinds are for DCRs that source data from an in-VM agent
# (syslog, performance counters, etc.) and have associated agent-side
# bindings. For Managed Prometheus the DCR is just a routing pipe — the
# data source is an HTTP remote-write call from outside Azure compute and
# the only stream involved is the built-in `Microsoft-PrometheusMetrics`.
# Setting kind=Linux with this stream fails 400 InvalidPayload.
resource "azurerm_monitor_data_collection_rule" "amw" {
  name                        = "${var.cluster_name}-amw-dcr"
  resource_group_name         = data.azurerm_resource_group.this.name
  location                    = var.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.amw.id

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.this.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  tags = local.tags
}

################################################################################
# Workload Identity — grafana-agent remote-write into AMW via DCR
#
# Grafana Agent in the cluster (running with this UAMI) calls the DCE
# ingestion endpoint with an AAD token. The `Monitoring Metrics Publisher`
# role must be assigned at the DCR scope — assigning it at the AMW scope
# does NOT grant ingestion (Azure checks the DCR, not the AMW).
################################################################################

module "grafana_agent_amw_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-grafana-agent-amw"
  resource_group  = local.resource_group_name
  location        = var.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "monitoring"
  service_account = "grafana-agent"
  scope           = azurerm_monitor_data_collection_rule.amw.id

  role_assignments = ["Monitoring Metrics Publisher"]

  tags = local.tags
}

################################################################################
# Azure Managed Grafana
#
# - System-assigned identity is used to authenticate to AMW + Azure Monitor.
# - public_network_access_enabled = true so the AMG endpoint is reachable.
#   (Set to false and add private endpoint for production hardening.)
# - api_key_enabled = true so we can issue a service-account-style token to
#   the in-cluster grafana-operator (so it can push GrafanaDashboard CRs).
################################################################################

resource "azurerm_dashboard_grafana" "this" {
  name                              = local.grafana_name
  resource_group_name               = data.azurerm_resource_group.this.name
  location                          = var.location
  api_key_enabled                   = true
  deterministic_outbound_ip_enabled = false
  public_network_access_enabled     = true
  grafana_major_version             = "11"
  sku                               = var.grafana_sku
  zone_redundancy_enabled           = var.grafana_zone_redundancy_enabled

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }

  tags = local.tags
}

################################################################################
# RBAC — Grafana system identity reads from AMW + Azure Monitor
################################################################################

resource "azurerm_role_assignment" "grafana_amw_reader" {
  scope                = azurerm_monitor_workspace.this.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "grafana_subscription_monitoring_reader" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_dashboard_grafana.this.identity[0].principal_id
}

################################################################################
# RBAC — Human users on Grafana
################################################################################

resource "azurerm_role_assignment" "grafana_admins" {
  for_each             = toset(var.grafana_admin_object_ids)
  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Admin"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "grafana_editors" {
  for_each             = toset(var.grafana_editor_object_ids)
  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Editor"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "grafana_viewers" {
  for_each             = toset(var.grafana_viewer_object_ids)
  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Viewer"
  principal_id         = each.value
}
