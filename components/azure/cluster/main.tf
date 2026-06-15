locals {
  cluster_name = "${var.resource_group_name}-aks"

  tags = merge(var.tags, {
    Component = "cluster"
    Team      = var.team
  })
}

################################################################################
# Resource Group
################################################################################

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}

################################################################################
# Log Analytics Workspace (for Container Insights)
################################################################################

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${local.cluster_name}-logs"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.tags
}

################################################################################
# AKS Cluster
################################################################################

resource "azurerm_kubernetes_cluster" "this" {
  name                = local.cluster_name
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  dns_prefix          = local.cluster_name

  # K8s version + support tier — see variables.tf for the trade-off matrix.
  # Verify availability with: az aks get-versions --location <region> -o table
  kubernetes_version        = var.cluster_version
  sku_tier                  = var.sku_tier
  support_plan              = var.support_plan
  private_cluster_enabled   = !var.cluster_endpoint_public_access
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # BYO CNI — Cilium is installed by cluster-bootstrap with aksbyocni.enabled=true.
  # Required by NAP when not using Azure CNI overlay + AKS-managed Cilium.
  #
  # CIDR topology — three ranges MUST stay disjoint:
  #   1. VNet            — set by network component (var.vnet_cidr, default 10.0.0.0/16)
  #   2. Pod CIDR        — set by Cilium in aks-gitops/addons/networking/cilium/values.yaml
  #                        (ipam.operator.clusterPoolIPv4PodCIDRList, default 10.244.0.0/16)
  #   3. Service CIDR    — var.service_cidr (default 10.96.0.0/16)
  #
  # If you change any of these, audit the other two for overlap. AKS only
  # catches collisions at cluster-create time, not in tofu plan.
  network_profile {
    network_plugin    = "none"
    service_cidr      = var.service_cidr
    dns_service_ip    = cidrhost(var.service_cidr, 10)
    load_balancer_sku = "standard"
    outbound_type     = "userAssignedNATGateway"
  }

  # Node Auto Provisioning — Microsoft-managed Karpenter control plane. The
  # operator runs in the AKS control plane (no Helm install). aks-gitops
  # karpenter-resources/ supplies the NodePool + AKSNodeClass CRs that NAP
  # consumes to provision nodes.
  node_provisioning_profile {
    mode = "Auto"
  }

  # IP allowlist for the public API endpoint. Only applies when the cluster
  # is public (private_cluster_enabled=false). If api_authorized_ip_ranges is
  # empty, the public endpoint is unrestricted.
  dynamic "api_server_access_profile" {
    for_each = var.cluster_endpoint_public_access && length(var.api_authorized_ip_ranges) > 0 ? [1] : []
    content {
      # Cluster egress IPs (NAT Gateway public IPs) are auto-merged into the
      # allowlist. Without this, nodes can't reach the API server because
      # they egress through the NAT IPs which wouldn't otherwise be allowed
      # — causing VMExtensionError_K8SAPIServerConnFail during create.
      #
      # Filter to IPv4 CIDRs only — AKS rejects IPv6 entries with
      # "must start with IPV4 address and/or slash". Common trap: a Mac
      # on dual-stack with `curl ifconfig.me` may return an IPv6 address
      # and bake it straight into TF_VAR_api_authorized_ip_ranges. Rather
      # than failing the caller's run, drop anything that doesn't parse
      # as IPv4 (presence of a colon means IPv6).
      authorized_ip_ranges = [
        for cidr in distinct(concat(
          var.api_authorized_ip_ranges,
          [for ip in var.egress_public_ips : "${ip}/32"],
        )) : cidr if !can(regex(":", cidr))
      ]
    }
  }

  # System node pool runs CriticalAddonsOnly workloads (kube-system DaemonSets,
  # ArgoCD, cert-manager, etc.). NAP manages everything else, so the system
  # pool is a fixed count. Azure rejects NAP=Auto + auto_scaling_enabled=true
  # in the system pool (they'd conflict over count management).
  default_node_pool {
    name            = "system"
    vm_size         = var.system_node_vm_size
    os_disk_size_gb = var.system_node_disk_size
    vnet_subnet_id  = var.private_subnet_ids[0]
    node_count      = var.system_node_count

    only_critical_addons_enabled = true

    node_labels = {
      "node-role" = "system"
    }
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenant_id
  }

  identity {
    type = "SystemAssigned"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  tags = local.tags
}

################################################################################
# Kubernetes-API RBAC for the Deployer
#
# AKS uses Azure RBAC for Kubernetes Authorization (azure_rbac_enabled=true on
# the cluster). Azure-plane roles (Owner / Contributor on the cluster) DO NOT
# grant kube-apiserver access. Without this assignment, `kubectl`, `helm`, and
# the Terraform kubernetes/helm providers all fail with
# `User does not have access to the resource in Azure` when listing secrets,
# CRDs, anything. Granting `Azure Kubernetes Service RBAC Cluster Admin` to the
# deployer principal at cluster scope makes cluster-bootstrap work end-to-end
# from a fresh apply.
################################################################################

resource "azurerm_role_assignment" "deployer_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

################################################################################
# Cluster identity → Network Contributor on the workload VNet
#
# Required for AKS Node Auto Provisioning (NAP / Karpenter). When NAP wants
# to provision a worker node, the AKS control plane's system-assigned
# identity needs `Microsoft.Network/virtualNetworks/subnets/read` (and
# write to attach the NIC) on the workload VNet — otherwise the AKSNodeClass
# never goes Ready, the NodePool stays Ready=False, and every pod that
# doesn't tolerate the system-pool taint sits Pending forever.
#
# The symptom is loud-but-misleading: addon Helm releases install fine,
# their Deployments get created, but pods stay Pending with no scheduling
# events because NAP can't even discover the subnet to provision nodes.
# Check `kubectl describe aksnodeclass.karpenter.azure.com default` —
# `SubnetsReady=False, Reason=SubnetUnknownError` with a 403 from
# `Microsoft.Network/virtualNetworks/subnets/read` confirms the missing
# role assignment.
################################################################################

resource "azurerm_role_assignment" "cluster_identity_network_contributor" {
  scope                = var.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}
