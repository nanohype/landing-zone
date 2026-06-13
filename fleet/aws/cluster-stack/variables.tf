# Inputs a provider-opentofu Workspace passes (eks-fleet's Cluster composition).
# Names + defaults track the wrapped components/aws/{network,cluster} modules.

variable "region" {
  description = "AWS region"
  type        = string
}

variable "environment" {
  description = "Environment tier (dev, staging, production) — prefixes resource names + tags"
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
  description = "IAM path for the cluster's IAM roles + policies. \"/eks-fleet/\" for cross-account fleet-vend gating; \"/\" (default) for same-account."
  type        = string
  default     = "/"
}

variable "cluster_permissions_boundary_arn" {
  description = "Permissions-boundary ARN for the cluster's IAM roles. Empty (default) = no boundary; inert under fleet-vend's path-only gate."
  type        = string
  default     = ""
}

# --- cluster ----------------------------------------------------------------
variable "cluster_name" {
  description = "EKS cluster base name; the component prefixes it with environment"
  type        = string
  default     = "eks"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_public_access" {
  description = "Enable the public EKS API endpoint"
  type        = bool
  default     = true
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
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "max_azs" {
  description = "Maximum availability zones"
  type        = number
  default     = 3
}

variable "nat_gateways" {
  description = "Number of NAT gateways (1 dev, 2 staging, 3 production)"
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
