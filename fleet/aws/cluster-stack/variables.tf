# Inputs a provider-terraform Workspace passes (eks-fleet's Cluster composition).
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

# --- cluster ----------------------------------------------------------------
variable "cluster_name" {
  description = "EKS cluster base name; the component prefixes it with environment"
  type        = string
  default     = "eks"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35"
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

variable "tags" {
  description = "Additional tags merged onto every resource"
  type        = map(string)
  default     = {}
}
