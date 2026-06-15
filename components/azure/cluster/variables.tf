variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD tenant ID"
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

variable "vnet_id" {
  description = "ID of the virtual network"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs"
  type        = list(string)
}

variable "team" {
  description = "Team name for resource tagging"
  type        = string
}

################################################################################
# Cluster version & SKU
################################################################################

variable "cluster_version" {
  description = "Kubernetes minor version (e.g. '1.35'). Verify current support with: az aks get-versions --location <region> -o table. Latest GA in Standard support is the target; bump every few quarters as new minors land."
  type        = string
  default     = "1.35"
}

variable "sku_tier" {
  description = "AKS control plane SKU. 'Standard' is free with ~14mo Standard Support per K8s minor. 'Premium' (~$432/mo) enables AKSLongTermSupport for 2-year support windows on older minors."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be one of: Free, Standard, Premium."
  }
}

variable "support_plan" {
  description = "Support plan tied to sku_tier. 'KubernetesOfficial' for Standard/Free. 'AKSLongTermSupport' requires Premium tier and an LTS-eligible K8s minor."
  type        = string
  default     = "KubernetesOfficial"

  validation {
    condition     = contains(["KubernetesOfficial", "AKSLongTermSupport"], var.support_plan)
    error_message = "support_plan must be 'KubernetesOfficial' or 'AKSLongTermSupport'."
  }
}

################################################################################
# API server access
################################################################################

variable "cluster_endpoint_public_access" {
  description = "Enable public access to the AKS cluster endpoint"
  type        = bool
  default     = false
}

variable "api_authorized_ip_ranges" {
  description = "List of CIDRs allowed to reach the public AKS API endpoint. Empty list = unrestricted public access. Ignored when cluster_endpoint_public_access=false (private cluster). Set via TF_VAR_api_authorized_ip_ranges in your shell to keep your IP out of git. The cluster's own egress IPs (from egress_public_ips) are auto-merged."
  type        = list(string)
  default     = []
}

variable "egress_public_ips" {
  description = "Public IP addresses of the cluster's egress (e.g., NAT Gateway public IPs from the network component). Auto-merged into the API authorized_ip_ranges so node→API-server traffic isn't blocked when an allowlist is in effect. Required when outbound_type='userAssignedNATGateway' and api_authorized_ip_ranges is non-empty."
  type        = list(string)
  default     = []
}

################################################################################
# Network CIDRs (must stay disjoint from VNet CIDR and Cilium pod CIDR)
################################################################################

variable "service_cidr" {
  description = "Kubernetes service CIDR. Must NOT overlap with the VNet CIDR (network component) or the Cilium pod CIDR (aks-gitops cilium values.yaml). Default 10.96.0.0/16 is the K8s convention and is disjoint from the default VNet 10.0.0.0/16."
  type        = string
  default     = "10.96.0.0/16"

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a valid CIDR (e.g., 10.96.0.0/16)."
  }
}

################################################################################
# System node pool — runs CriticalAddonsOnly workloads (foundational addons
# that must come up before NAP can provision workload nodes: ArgoCD,
# cert-manager, external-secrets, cilium operator, kube-system DaemonSets).
# Everything else runs on NAP-provisioned nodes.
################################################################################

variable "system_node_count" {
  description = "Fixed node count for the system node pool. NAP cannot coexist with system-pool autoscaling — Azure rejects the combination at create time. Set 1 for dev, 3+ for prod (HA control plane scheduling)."
  type        = number
  default     = 1
}

variable "system_node_vm_size" {
  description = "VM size for system node pool. D4s_v6 (4 vCPU/16 GiB, Sapphire Rapids/Genoa) is the modern baseline — Microsoft is phasing out v5 (DSv5 starts at 0 quota in many regions; Dsv6 ships with 10). D2s_v6 (2 vCPU/8 GiB) is fine for dev/sandbox."
  type        = string
  default     = "Standard_D4s_v6"
}

variable "system_node_disk_size" {
  description = "OS disk size in GB for system node pool nodes."
  type        = number
  default     = 100
}

variable "tags" {
  description = "Org-wide tags injected by the root config (azurerm has no provider default_tags)."
  type        = map(string)
  default     = {}
}
