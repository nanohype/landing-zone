variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string

  # Format contract, not a closed enum: the platform legitimately uses development, staging,
  # production, prod, hub, org, management, and per-workload derivations, so pinning a
  # fixed set would reject valid environments. This still catches empty/uppercase/typo'd
  # values before they flow into resource names, tags, SSM paths, and the IPAM-pool tag
  # (org-ipam-<environment>) this component discovers its CIDR pool by.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

# --- IPAM (the shared VPC CIDR is always drawn from an org IPAM pool) ---------
variable "ipam_pool_id" {
  description = <<-EOT
    IPAM pool the shared VPC CIDR is drawn from. Empty (default) = discover the org env
    sub-pool automatically by its tag (org-ipam-<environment>, the tag org-networking
    stamps on each env sub-pool) via data.aws_vpc_ipam_pools. Set it explicitly to pin a
    specific pool — the escape hatch for when the RAM-shared pool is not tag-discoverable
    from this account. Cross-account, the discovered/pinned pool is the org IPAM env
    sub-pool shared in over RAM from the management account.
  EOT
  type        = string
  default     = ""
}

variable "ipam_netmask_length" {
  description = "Netmask length of the VPC CIDR to allocate from the IPAM pool (e.g. 16 for a /16)."
  type        = number
  default     = 16

  # Subnets are carved 8 bits smaller than the VPC block (cidrsubnet(..., 8, ...) in
  # main.tf), so a /20 base is the smallest that still yields /28 subnets — AWS's minimum
  # subnet size — across the public/private/intra tiers. A longer base carves sub-/28
  # subnets AWS rejects at apply, and anything past /24 fails even earlier with a raw
  # cidrsubnet "insufficient address space" provider error instead of this message.
  validation {
    condition     = var.ipam_netmask_length >= 16 && var.ipam_netmask_length <= 20
    error_message = "ipam_netmask_length must be between 16 and 20 — subnets are carved 8 bits smaller than the VPC block, so a base longer than /20 would produce subnets below AWS's /28 minimum."
  }
}

# --- Topology / egress --------------------------------------------------------
variable "max_azs" {
  description = "Maximum number of availability zones to spread subnets across"
  type        = number
  default     = 3
}

variable "nat_gateways" {
  description = "Number of NAT gateways (1 for development, 2 for staging, 3 for production). Ignored under centralized_egress (0 NAT gateways)."
  type        = number
  default     = 1
}

variable "transit_gateway_id" {
  description = <<-EOT
    Transit gateway the shared VPC attaches to. Empty (default) = no attachment, local NAT
    egress only. When set, a TGW VPC attachment is placed on the private subnets and a
    10.0.0.0/8 route to the TGW is added to every private route table so the shared VPC
    reaches the rest of the org's address space. Required when centralized_egress = true.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = !var.centralized_egress || var.transit_gateway_id != ""
    error_message = "transit_gateway_id is required when centralized_egress = true — there is nothing to route the default egress to without a transit gateway."
  }
}

variable "centralized_egress" {
  description = <<-EOT
    Route private egress through the transit gateway to a central egress VPC instead of a
    local NAT gateway. false (default) = local NAT. true = zero NAT gateways; the private
    default route (0.0.0.0/0) points at the TGW, where an egress-network hub carries the
    traffic to the internet. Requires transit_gateway_id.
  EOT
  type        = bool
  default     = false
}

# --- Endpoints ----------------------------------------------------------------
variable "enable_vpc_endpoints" {
  description = "Build the private endpoint set an adopting EKS cluster needs (S3 gateway + the interface endpoints). Owner-run: the adopting workload account cannot build endpoints in a VPC it does not own."
  type        = bool
  default     = true
}

variable "enable_eks_interface_endpoint" {
  description = <<-EOT
    Create the EKS API interface endpoint (private DNS for eks.<region>.amazonaws.com).
    Keep enabled for a normal cluster VPC. Set FALSE only when the shared VPC also hosts a
    provisioning hub that must resolve the IRSA OIDC issuer oidc.eks.<region>.amazonaws.com
    from inside the VPC (the EKS-API endpoint's private DNS would otherwise shadow it).
  EOT
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch for the shared VPC (the owner logs the shared VPC on behalf of every adopting account)."
  type        = bool
  default     = false
}

# --- RAM share ----------------------------------------------------------------
variable "consumer_account_ids" {
  description = <<-EOT
    Workload account IDs the shared subnets are RAM-shared to. Each adopting account runs
    the network component in adopt mode against these subnets and a cluster with
    stamp_subnet_tags = false. Empty by default; a real share is a per-engagement
    activation. The owner-side contract check fails plan-time validation when this is empty.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.consumer_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "each consumer_account_ids entry must be a 12-digit AWS account ID."
  }
}

variable "share_public_subnets" {
  description = "RAM-share the public subnets too (for internet-facing load balancers in adopting clusters). Private subnets are always shared; public is opt-in."
  type        = bool
  default     = false
}

# --- Common -------------------------------------------------------------------
variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
