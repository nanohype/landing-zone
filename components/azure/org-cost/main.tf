data "azurerm_subscription" "current" {}

locals {
  tags = merge(var.tags, {
    Component = "org-cost"
    Team      = var.team
  })
}

################################################################################
# Resource Group
################################################################################

resource "azurerm_resource_group" "cost" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

################################################################################
# Action Group — Cost Alert Notifications
################################################################################

resource "azurerm_monitor_action_group" "cost_alerts" {
  name                = "org-cost-alerts"
  resource_group_name = azurerm_resource_group.cost.name
  short_name          = "CostAlerts"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.budget_alert_emails
    content {
      name          = "cost-alert-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }
}

################################################################################
# Subscription Budget
################################################################################

resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "org-monthly-budget"
  subscription_id = data.azurerm_subscription.current.id
  amount          = var.budget_limit
  time_grain      = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  dynamic "notification" {
    for_each = var.budget_alert_thresholds
    content {
      operator       = "GreaterThanOrEqualTo"
      threshold      = notification.value
      threshold_type = notification.value >= 100 ? "Actual" : "Forecasted"
      contact_groups = [azurerm_monitor_action_group.cost_alerts.id]
    }
  }
}

################################################################################
# Storage Account — Cost Export Destination
################################################################################

resource "azurerm_storage_account" "cost_export" {
  count = var.enable_cost_export ? 1 : 0

  name                     = var.export_storage_account_name
  resource_group_name      = azurerm_resource_group.cost.name
  location                 = azurerm_resource_group.cost.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false

  tags = merge(local.tags, { Name = var.export_storage_account_name })
}

resource "azurerm_storage_container" "cost_export" {
  count = var.enable_cost_export ? 1 : 0

  name               = "cost-exports"
  storage_account_id = azurerm_storage_account.cost_export[0].id
}

################################################################################
# Cost Management Export — Scheduled Cost Data Export
################################################################################

resource "azurerm_subscription_cost_management_export" "daily" {
  count = var.enable_cost_export ? 1 : 0

  name                         = "org-daily-cost-export"
  subscription_id              = data.azurerm_subscription.current.id
  recurrence_type              = "Daily"
  recurrence_period_start_date = var.export_start_date
  recurrence_period_end_date   = var.export_end_date

  export_data_storage_location {
    container_id     = azurerm_storage_container.cost_export[0].id
    root_folder_path = "/cost-exports"
  }

  export_data_options {
    type       = "ActualCost"
    time_frame = "MonthToDate"
  }
}
