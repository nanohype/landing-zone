variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string

  # Format contract, not a closed enum: the platform legitimately uses dev, staging,
  # production, prod, hub, org, management, and per-workload derivations, so pinning a
  # fixed set would reject valid environments. This still catches empty/uppercase/typo'd
  # values before they flow into resource names, tags, and SSM paths.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (used for Karpenter discovery tags)"
  type        = string
  default     = "eks"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "max_azs" {
  description = "Maximum number of availability zones to use"
  type        = number
  default     = 3
}

variable "nat_gateways" {
  description = "Number of NAT gateways (1 for dev, 2 for staging, 3 for production)"
  type        = number
  default     = 1
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch"
  type        = bool
  default     = false
}

variable "enable_vpc_endpoints" {
  description = "Enable VPC endpoints for AWS services"
  type        = bool
  default     = true
}

variable "enable_eks_interface_endpoint" {
  description = <<-EOT
    Create the EKS API interface endpoint (private DNS for eks.<region>.amazonaws.com).
    Keep enabled for normal clusters. Set FALSE for a provisioning hub (an eks-fleet
    management cluster that vends other clusters from inside this VPC): the endpoint's
    private DNS creates a private hosted zone for eks.<region>.amazonaws.com that owns
    the whole subtree, so it shadows the IRSA OIDC issuer oidc.eks.<region>.amazonaws.com
    (NXDOMAIN) — which breaks data.tls_certificate when the in-VPC runner provisions a
    cluster's OIDC provider. With it off, the EKS API resolves publicly via NAT.
  EOT
  type        = bool
  default     = true
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
