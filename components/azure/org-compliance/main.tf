data "azurerm_subscription" "current" {}

locals {
  tags = merge(var.tags, {
    Component = "org-compliance"
    Team      = var.team
  })
}

################################################################################
# Resource Group
################################################################################

resource "azurerm_resource_group" "compliance" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

################################################################################
# Log Analytics Workspace — Central Audit Workspace
################################################################################

resource "azurerm_log_analytics_workspace" "audit" {
  name                = var.workspace_name
  location            = azurerm_resource_group.compliance.location
  resource_group_name = azurerm_resource_group.compliance.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days

  tags = merge(local.tags, { Name = var.workspace_name })
}

################################################################################
# Storage Account — Audit Log Archive
################################################################################

resource "azurerm_storage_account" "audit_archive" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.compliance.name
  location                 = azurerm_resource_group.compliance.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    delete_retention_policy {
      days = 90
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  tags = merge(local.tags, { Name = var.storage_account_name })
}

resource "azurerm_storage_management_policy" "audit_lifecycle" {
  storage_account_id = azurerm_storage_account.audit_archive.id

  rule {
    name    = "archive-old-logs"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["insights-activity-logs/"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 90
        tier_to_archive_after_days_since_modification_greater_than = 365
        delete_after_days_since_modification_greater_than          = var.archive_retention_days
      }
    }
  }
}

################################################################################
# Activity Log — Diagnostic Setting (Subscription Level)
################################################################################

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  count = var.enable_activity_log ? 1 : 0

  name                       = "org-activity-log-export"
  target_resource_id         = data.azurerm_subscription.current.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.audit.id
  storage_account_id         = azurerm_storage_account.audit_archive.id

  enabled_log {
    category = "Administrative"
  }

  enabled_log {
    category = "Security"
  }

  enabled_log {
    category = "ServiceHealth"
  }

  enabled_log {
    category = "Alert"
  }

  enabled_log {
    category = "Recommendation"
  }

  enabled_log {
    category = "Policy"
  }

  enabled_log {
    category = "Autoscale"
  }

  enabled_log {
    category = "ResourceHealth"
  }
}

################################################################################
# Azure Policy Assignment — CIS Benchmark
################################################################################

resource "azurerm_subscription_policy_assignment" "cis_benchmark" {
  count = var.enable_cis_benchmark ? 1 : 0

  name                 = "org-cis-benchmark"
  display_name         = "CIS Microsoft Azure Foundations Benchmark"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/06f19060-9e68-4070-92ca-f15cc126059e"
  location             = var.location

  identity {
    type = "SystemAssigned"
  }
}
