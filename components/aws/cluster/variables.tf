variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster base name (prefixed with environment)"
  type        = string
  default     = "eks"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35"
}

# Network inputs (from network component)
variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS nodes"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for load balancers"
  type        = list(string)
}

# Cluster access
variable "cluster_endpoint_public_access" {
  description = "Enable public API endpoint (requires VPC endpoints for eks and eks-auth if false)"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API endpoint. Empty list = unrestricted (the AWS default). Set to your operator IP(s) to lock it down."
  type        = list(string)
  default     = []
}

variable "access_entries" {
  description = <<-EOT
    Extra EKS access entries for IAM principals, keyed by name. The principal
    that applies this component is already granted cluster-admin via
    enable_cluster_creator_admin_permissions, so this defaults to empty;
    populate it per-environment with real principal ARNs (CI roles, SSO admin
    roles, etc.). Do NOT put placeholder ARNs here — an invalid principal_arn
    fails the apply.
  EOT
  type        = any
  default     = {}
}

# System node group
variable "system_node_instance_types" {
  description = "Instance types for system node group"
  type        = list(string)
  default     = ["m5a.xlarge", "m5.xlarge"]
}

variable "system_node_min_size" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 6
}

variable "system_node_desired_size" {
  description = "Desired number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_disk_size" {
  description = "Disk size in GB for system nodes"
  type        = number
  default     = 100
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
