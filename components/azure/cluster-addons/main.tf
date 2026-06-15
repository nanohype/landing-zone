locals {
  # Derive resource group from cluster name convention: {rg}-aks
  resource_group_name = trimsuffix(var.cluster_name, "-aks")
  identity_prefix     = "${var.cluster_name}-wi"

  tags = merge(var.tags, {
    Component = "cluster-addons"
    Team      = var.team
  })
}

data "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = local.resource_group_name
}

################################################################################
# Workload Identity — External DNS
################################################################################

module "external_dns_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-external-dns"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "external-dns"
  service_account = "external-dns"
  scope           = "/subscriptions/${var.subscription_id}"

  role_assignments = ["DNS Zone Contributor"]

  tags = local.tags
}

################################################################################
# Workload Identity — cert-manager
################################################################################

module "cert_manager_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-cert-manager"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "cert-manager"
  service_account = "cert-manager"
  scope           = "/subscriptions/${var.subscription_id}"

  role_assignments = ["DNS Zone Contributor"]

  tags = local.tags
}

################################################################################
# Workload Identity — External Secrets Operator
################################################################################

module "external_secrets_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-external-secrets"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "external-secrets"
  service_account = "external-secrets"
  scope           = "/subscriptions/${var.subscription_id}"

  role_assignments = ["Key Vault Secrets User"]

  tags = local.tags
}

################################################################################
# Workload Identity — Loki (log storage)
################################################################################

module "loki_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-loki"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "monitoring"
  service_account = "loki"
  scope           = azurerm_storage_account.loki.id

  role_assignments = ["Storage Blob Data Contributor"]

  tags = local.tags
}

################################################################################
# Workload Identity — Tempo (trace storage)
################################################################################

module "tempo_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-tempo"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "monitoring"
  service_account = "tempo"
  scope           = azurerm_storage_account.tempo.id

  role_assignments = ["Storage Blob Data Contributor"]

  tags = local.tags
}

################################################################################
# Workload Identity — OpenCost (cost data via Azure Cost Management)
################################################################################

module "opencost_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-opencost"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "opencost"
  service_account = "opencost"
  scope           = "/subscriptions/${var.subscription_id}"

  role_assignments = ["Cost Management Reader"]

  tags = local.tags
}

################################################################################
# Workload Identity — KEDA (event-driven autoscaling)
#
# KEDA uses TriggerAuthentication CRs to attach per-scaler identities; the
# operator SA only needs token federation. Workload-specific role grants
# happen at the scaler level (ServiceBus Data Receiver, Storage Queue Data
# Reader, etc.) and are out of scope for the cluster addon layer.
################################################################################

module "keda_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-keda"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "keda"
  service_account = "keda-operator"

  tags = local.tags
}

################################################################################
# Workload Identity — Argo Events
################################################################################

module "argo_events_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-argo-events"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "argo-events"
  service_account = "argo-events-controller-manager"

  tags = local.tags
}

################################################################################
# Workload Identity — Argo Workflows (artifact storage on Azure Blob)
################################################################################

module "argo_workflows_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-argo-workflows"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "argo-workflows"
  service_account = "argo-workflows-server"
  scope           = azurerm_storage_account.argo_workflows.id

  role_assignments = ["Storage Blob Data Contributor"]

  tags = local.tags
}

################################################################################
# Workload Identity — Velero
#
# Velero needs Storage Blob Data Contributor on the backup container and
# Disk Snapshot Contributor on the AKS node resource group (where node disks
# live and where snapshots are created).
################################################################################

module "velero_identity" {
  source = "../../../modules/azure/workload-identity"

  identity_name   = "${local.identity_prefix}-velero"
  resource_group  = local.resource_group_name
  location        = data.azurerm_kubernetes_cluster.this.location
  oidc_issuer_url = var.oidc_issuer_url
  namespace       = "velero"
  service_account = "velero"
  scope           = azurerm_storage_account.velero.id

  role_assignments = ["Storage Blob Data Contributor"]

  tags = local.tags
}

resource "azurerm_role_assignment" "velero_disk_snapshot" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_kubernetes_cluster.this.node_resource_group}"
  role_definition_name = "Disk Snapshot Contributor"
  principal_id         = module.velero_identity.principal_id
}

# Karpenter on AKS runs as Node Auto Provisioning — Microsoft manages the
# operator and its identity. No workload-identity / role assignments are
# needed from this component. NodePool + AKSNodeClass CRs in
# aks-gitops karpenter-resources/ drive node provisioning.

################################################################################
# Storage Account — Loki (log storage)
################################################################################

resource "azurerm_storage_account" "loki" {
  name                     = substr("${replace(var.cluster_name, "-", "")}loki${replace(var.subscription_id, "-", "")}", 0, 24)
  resource_group_name      = local.resource_group_name
  location                 = data.azurerm_kubernetes_cluster.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "loki" {
  name                  = "loki-chunks"
  storage_account_id    = azurerm_storage_account.loki.id
  container_access_type = "private"
}

################################################################################
# Storage Account — Tempo (trace storage)
################################################################################

resource "azurerm_storage_account" "tempo" {
  name                     = substr("${replace(var.cluster_name, "-", "")}tempo${replace(var.subscription_id, "-", "")}", 0, 24)
  resource_group_name      = local.resource_group_name
  location                 = data.azurerm_kubernetes_cluster.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tempo" {
  name                  = "tempo-traces"
  storage_account_id    = azurerm_storage_account.tempo.id
  container_access_type = "private"
}

################################################################################
# Storage Account — Velero (backup storage)
################################################################################

resource "azurerm_storage_account" "velero" {
  name                     = substr("${replace(var.cluster_name, "-", "")}backups${replace(var.subscription_id, "-", "")}", 0, 24)
  resource_group_name      = local.resource_group_name
  location                 = data.azurerm_kubernetes_cluster.this.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    delete_retention_policy {
      days = 30
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "velero" {
  name                  = "velero"
  storage_account_id    = azurerm_storage_account.velero.id
  container_access_type = "private"
}

################################################################################
# Storage Account — Argo Workflows (artifact storage)
################################################################################

resource "azurerm_storage_account" "argo_workflows" {
  name                     = substr("${replace(var.cluster_name, "-", "")}artifacts${replace(var.subscription_id, "-", "")}", 0, 24)
  resource_group_name      = local.resource_group_name
  location                 = data.azurerm_kubernetes_cluster.this.location
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

resource "azurerm_storage_container" "argo_workflows" {
  name                  = "argo-artifacts"
  storage_account_id    = azurerm_storage_account.argo_workflows.id
  container_access_type = "private"
}
