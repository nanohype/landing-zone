variable "vpc_id" {
  description = "VPC the endpoints attach to"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs the interface endpoints place their ENIs in (one per AZ). Unused when enable_interface_endpoints is false."
  type        = list(string)
  default     = []
}

variable "route_table_ids" {
  description = "Route table IDs the S3 gateway endpoint associates with (private + public route tables). Unused when enable_s3_gateway_endpoint is false."
  type        = list(string)
  default     = []
}

variable "security_group_id" {
  description = "Security group applied to every interface endpoint ENI (allows 443 from the VPC). Optional — only referenced when enable_interface_endpoints is true, so a gateway-only caller can leave it unset."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name — prefixes each endpoint's Name tag"
  type        = string
}

variable "enable_s3_gateway_endpoint" {
  description = <<-EOT
    Create the S3 gateway endpoint. A gateway endpoint has NO hourly or data-processing
    charge (unlike interface endpoints), and it keeps S3 traffic — including ECR image
    layers, which are stored in S3 — inside the VPC instead of paying NAT data processing.
    So it is worth keeping on even for a minimal-footprint VPC. Default on.
  EOT
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = <<-EOT
    Create the interface endpoint set (ecr.api, ecr.dkr, secretsmanager, ssm, sts, eks-auth,
    aps-workspaces, and eks when enable_eks_interface_endpoint is also true). Interface
    endpoints carry an hourly charge per endpoint per AZ plus data processing, so a
    minimal-footprint VPC leaves them off and reaches those services over NAT; turn them on
    for private connectivity or to drop the NAT data cost on high-volume paths. Default on.
    When off, security_group_id is not required.
  EOT
  type        = bool
  default     = true
}

variable "enable_eks_interface_endpoint" {
  description = <<-EOT
    Create the EKS API interface endpoint (private DNS for eks.<region>.amazonaws.com).
    Only takes effect when enable_interface_endpoints is true. Keep enabled for a normal
    cluster VPC. Set FALSE for a provisioning hub VPC (an eks-fleet management cluster that
    vends other clusters from inside this VPC): the endpoint's private DNS creates a private
    hosted zone for eks.<region>.amazonaws.com that owns the whole subtree, so it shadows the
    IRSA OIDC issuer oidc.eks.<region>.amazonaws.com (NXDOMAIN) — which breaks
    data.tls_certificate when the in-VPC runner provisions a cluster's OIDC provider. With it
    off, the EKS API resolves publicly via NAT.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every endpoint"
  type        = map(string)
  default     = {}
}
