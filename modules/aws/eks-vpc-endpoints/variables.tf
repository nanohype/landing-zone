variable "vpc_id" {
  description = "VPC the endpoints attach to"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs the interface endpoints place their ENIs in (one per AZ)"
  type        = list(string)
}

variable "route_table_ids" {
  description = "Route table IDs the S3 gateway endpoint associates with (private + public route tables)"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group applied to every interface endpoint ENI (allows 443 from the VPC)"
  type        = string
}

variable "environment" {
  description = "Environment name — prefixes each endpoint's Name tag"
  type        = string
}

variable "enable_eks_interface_endpoint" {
  description = <<-EOT
    Create the EKS API interface endpoint (private DNS for eks.<region>.amazonaws.com).
    Keep enabled for a normal cluster VPC. Set FALSE for a provisioning hub VPC (an
    eks-fleet management cluster that vends other clusters from inside this VPC): the
    endpoint's private DNS creates a private hosted zone for eks.<region>.amazonaws.com
    that owns the whole subtree, so it shadows the IRSA OIDC issuer
    oidc.eks.<region>.amazonaws.com (NXDOMAIN) — which breaks data.tls_certificate when
    the in-VPC runner provisions a cluster's OIDC provider. With it off, the EKS API
    resolves publicly via NAT.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every endpoint"
  type        = map(string)
  default     = {}
}
