# Inputs a provider-opentofu Workspace passes (eks-fleet's Cluster composition).
# Names + defaults track the wrapped components/aws/{network,cluster} modules.

variable "region" {
  description = "AWS region"
  type        = string
}

variable "environment" {
  description = "Environment tier (development, staging, production) — prefixes resource names + tags"
  type        = string
}

variable "team" {
  description = "Owning team (tagging + ownership)"
  type        = string
}

variable "assume_role_arn" {
  description = "Cross-account role to assume to provision the cluster. Empty = use the runner's own identity (same-account vending)."
  type        = string
  default     = ""
}

variable "external_id" {
  description = "sts:ExternalId presented when assuming the cross-account vend role (must match the fleet-vend trust; ignored same-account)"
  type        = string
  default     = "eks-fleet"
}

variable "bootstrap_access_role_arn" {
  description = "IAM role granted cluster-admin via an EKS access entry so the cross-account bootstrap Workspace's ambient get-token can reach this cluster's API — set it to the hub's Crossplane role for cross-account vends. Empty (default) = same-account, where the creator is already admin."
  type        = string
  default     = ""
}

variable "portal_access_role_arn" {
  description = "The portal worker's per-account spoke role ARN, granted a read EKS access entry so portal can reach this cluster's API (mint tokens, watch tenants) with the same role it uses for eks:DescribeCluster. Empty (default) = portal not wired for this cluster."
  type        = string
  default     = ""
}

variable "cluster_iam_role_path" {
  description = "IAM path for the cluster's IAM roles + policies. \"/eks-fleet/\" for fleet-vend/fleet-hub gating; \"/\" (default) outside the fleet gate."
  type        = string
  default     = "/"
}

variable "cluster_permissions_boundary_arn" {
  description = "Permissions-boundary ARN for the cluster's IAM roles. Fleet vends MUST set it to the boundary of the fleet role running this Workspace — fleet-vend's for cross-account (SSM /eks-fleet/<env>/fleet-vend/vend_permissions_boundary_arn), fleet-hub's for same-account (SSM /eks-fleet/<env>/fleet-hub/hub_permissions_boundary_arn) — because the fleet roles' CreateRole gate rejects any cluster role that doesn't carry their ceiling. Empty (default) = no boundary (running outside the fleet gate)."
  type        = string
  default     = ""
}

# --- cluster ----------------------------------------------------------------
variable "cluster_name" {
  description = "EKS cluster base name; the component prefixes it with environment"
  type        = string
  default     = "platform"

  # no-doubled-env: reject a base name that repeats the environment token. The
  # cluster component composes local.cluster_name = "<environment>-<cluster_name>",
  # so a value equal to or prefixed with "<environment>-" (e.g. cluster_name =
  # "development-platform") produces a doubled "development-development-platform"
  # cluster name and every cluster-scoped IAM/KMS/S3 name derived from it. Mirrors
  # the guard the multi-tenant components carry on their base-name inputs.
  validation {
    condition     = var.cluster_name != var.environment && !startswith(var.cluster_name, "${var.environment}-")
    error_message = "cluster_name must not equal or be prefixed with the environment token '${var.environment}-': it composes into a doubled '<env>-<env>-...' cluster name."
  }
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_public_access" {
  description = "Enable the public EKS API endpoint — explicit opt-in; private by default"
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API (empty = unrestricted)"
  type        = list(string)
  default     = []
}

variable "system_node_instance_types" {
  description = "System node group instance types (Graviton/arm64)"
  type        = list(string)
  default     = ["m7g.xlarge", "m6g.xlarge"]
}

variable "system_node_min_size" {
  description = "Minimum system nodes"
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum system nodes"
  type        = number
  default     = 6
}

variable "system_node_desired_size" {
  description = "Desired system nodes"
  type        = number
  default     = 2
}

variable "system_node_disk_size" {
  description = "System node disk size (GB)"
  type        = number
  default     = 100
}

# --- network ----------------------------------------------------------------
variable "network_mode" {
  description = "create (default) — the stack owns the VPC. adopt — the stack participates in a VPC it does not own (same-account shared, or cross-account via RAM), referencing it by adopt_* IDs. In adopt mode the cluster's subnet-ownership tags are gated off (the network owner owns tagging)."
  type        = string
  default     = "create"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (create mode, literal allocation). Mutually exclusive with ipam_pool_id."
  type        = string
  default     = "10.0.0.0/16"
}

variable "ipam_pool_id" {
  description = "IPAM pool the VPC CIDR is drawn from (create mode). Empty (default) = literal allocation from vpc_cidr."
  type        = string
  default     = ""
}

variable "ipam_netmask_length" {
  description = "Netmask length of the VPC CIDR to allocate from ipam_pool_id (e.g. 16). 0 (default) = literal allocation."
  type        = number
  default     = 0
}

variable "transit_gateway_id" {
  description = "Transit gateway the VPC attaches to (create mode). Empty (default) = local NAT egress only. Requires an IPAM-allocated CIDR when set."
  type        = string
  default     = ""
}

variable "centralized_egress" {
  description = "Route private egress through the transit gateway instead of local NAT (create mode). false (default) = local NAT. Requires transit_gateway_id."
  type        = bool
  default     = false
}

variable "adopt_vpc_id" {
  description = "VPC ID to adopt (adopt mode). Required when network_mode = adopt."
  type        = string
  default     = ""
}

variable "adopt_private_subnet_ids" {
  description = "Private subnet IDs in the adopted VPC (adopt mode). Required, non-empty, when network_mode = adopt."
  type        = list(string)
  default     = []
}

variable "adopt_public_subnet_ids" {
  description = "Public subnet IDs in the adopted VPC (adopt mode). Empty is valid for a private-only cluster."
  type        = list(string)
  default     = []
}

variable "max_azs" {
  description = "Maximum availability zones"
  type        = number
  default     = 3
}

variable "nat_gateways" {
  description = "Number of NAT gateways (1 development, 2 staging, 3 production)"
  type        = number
  default     = 1
}

variable "enable_eks_interface_endpoint" {
  description = <<-EOT
    Create the EKS API interface endpoint. Leave true for normal vended clusters.
    Set FALSE for an eks-fleet provisioning hub: the endpoint's private DNS shadows
    the IRSA OIDC issuer (oidc.eks.<region>.amazonaws.com → NXDOMAIN), which breaks
    the in-VPC runner's data.tls_certificate when it creates a vended cluster's OIDC
    provider. With it off the EKS API resolves publicly via NAT.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags merged onto every resource"
  type        = map(string)
  default     = {}
}

variable "ttl_days" {
  description = "Days-to-live for an ephemeral spoke. 0 (default) tags the cluster Lifecycle=persistent and it is never auto-reaped. >0 tags Lifecycle=ephemeral + Expiry=<vend date + ttl_days> (resource-tagging standard) and the hub reaper deletes the Cluster CR past that date."
  type        = number
  default     = 0
}
