variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string

  # Format contract, not a closed enum: the platform legitimately uses development, staging,
  # production, prod, hub, org, management, and per-workload derivations, so pinning a
  # fixed set would reject valid environments. This still catches empty/uppercase/typo'd
  # values before they flow into resource names, tags, and SSM paths.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

variable "region" {
  description = "AWS region — also selects the AWS-managed S3 gateway prefix list the adopt preflight asserts against (com.amazonaws.<region>.s3)."
  type        = string
}

variable "network_mode" {
  description = <<-EOT
    create — this component owns a VPC: it builds the VPC, subnets, endpoints, egress,
    and the ELB role tags (the default).

    adopt — this component participates in a VPC it does not own (a shared VPC in the
    same account, or one shared cross-account via AWS RAM). It builds nothing: it
    resolves vpc_id / subnets / CIDR / AZs from the adopt_* inputs and re-exports them
    through the same outputs, so a consuming cluster wires against one interface either
    way. The owner (a shared-network account) runs the VPC, the endpoints, and the
    subnet tagging.
  EOT
  type        = string
  default     = "create"

  validation {
    condition     = can(regex("^(create|adopt)$", var.network_mode))
    error_message = "network_mode must be exactly \"create\" or \"adopt\"."
  }

  # The cross-mode contract (a field from the wrong side is a contradiction, not a no-op)
  # is enforced on each field's own variable below, referencing network_mode one way — the
  # levers reject adopt mode, the adopt_* inputs reject create mode. Anchoring both halves
  # here instead would make network_mode and the adopt_* variables reference each other and
  # form a validation cycle.
}

# --- create-mode inputs -----------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the VPC (create mode, literal allocation). Mutually exclusive with ipam_pool_id."
  type        = string
  default     = "10.0.0.0/16"
}

variable "ipam_pool_id" {
  description = <<-EOT
    IPAM pool the VPC CIDR is drawn from (create mode). Empty (default) = literal
    allocation from vpc_cidr. When set, the VPC CIDR is allocated from this pool at
    ipam_netmask_length and subnet blocks are carved from the pool's previewed CIDR.
    Cross-account, this is the org IPAM env sub-pool shared in over RAM.
  EOT
  type        = string
  default     = ""

  # A VPC CIDR comes from exactly one source. Setting an IPAM pool AND overriding the
  # literal vpc_cidr is contradictory — reject it rather than silently ignoring one.
  validation {
    condition     = var.ipam_pool_id == "" || var.vpc_cidr == "10.0.0.0/16"
    error_message = "ipam_pool_id and a non-default vpc_cidr are mutually exclusive — with an IPAM pool the CIDR is drawn from the pool, so leave vpc_cidr at its default."
  }

  # adopt mode participates in a VPC it does not own, so this create-mode lever has nothing
  # to act on — reject the combination rather than silently ignoring it.
  validation {
    condition     = var.network_mode != "adopt" || var.ipam_pool_id == ""
    error_message = "ipam_pool_id is a create-mode lever and does not apply when network_mode = adopt — leave it unset for an adopted VPC."
  }
}

variable "ipam_netmask_length" {
  description = "Netmask length of the VPC CIDR to allocate from ipam_pool_id (e.g. 16 for a /16). 0 (default) = unused (literal allocation)."
  type        = number
  default     = 0

  # An IPAM allocation needs a netmask; a literal allocation must not carry one. The upper
  # bound is 20, not the /28 the pool itself allows: subnets are carved 8 bits smaller than
  # the VPC block (cidrsubnet(..., 8, ...) in main.tf), so a /20 base is the smallest that
  # still yields /28 subnets — AWS's minimum subnet size — across the public/private/intra
  # tiers. A longer base (a /21 or beyond) carves sub-/28 subnets AWS rejects at apply, and
  # anything past /24 fails even earlier with a raw cidrsubnet "insufficient address space"
  # provider error instead of this message.
  validation {
    condition     = var.ipam_pool_id == "" ? var.ipam_netmask_length == 0 : (var.ipam_netmask_length >= 16 && var.ipam_netmask_length <= 20)
    error_message = "ipam_netmask_length must be 0 when no ipam_pool_id is set, and between 16 and 20 when one is — subnets are carved 8 bits smaller than the VPC block, so a base longer than /20 would produce subnets below AWS's /28 minimum."
  }
}

variable "transit_gateway_id" {
  description = <<-EOT
    Transit gateway the VPC attaches to (create mode). Empty (default) = no attachment,
    local NAT egress only. When set, a TGW VPC attachment is placed on the private
    subnets and a 10.0.0.0/8 route to the TGW is added to every private route table so
    the VPC reaches the rest of the org's address space. Requires an IPAM-allocated CIDR
    (a TGW route domain needs non-overlapping, IPAM-governed prefixes).
  EOT
  type        = string
  default     = ""

  # Overlapping literal /16s across VPCs break TGW routing. Requiring IPAM allocation
  # whenever a VPC joins the transit gateway keeps every attached prefix non-overlapping
  # by construction.
  validation {
    condition     = var.transit_gateway_id == "" || var.ipam_pool_id != ""
    error_message = "transit_gateway_id requires an IPAM-allocated CIDR (set ipam_pool_id) — a raw literal vpc_cidr can overlap another attached VPC and break TGW routing."
  }

  # adopt mode participates in a VPC it does not own, so this create-mode lever has nothing
  # to act on — reject the combination rather than silently ignoring it.
  validation {
    condition     = var.network_mode != "adopt" || var.transit_gateway_id == ""
    error_message = "transit_gateway_id is a create-mode lever and does not apply when network_mode = adopt — the VPC owner runs the attachment for an adopted VPC."
  }
}

variable "centralized_egress" {
  description = <<-EOT
    Route private egress through the transit gateway to a central egress VPC instead of
    a local NAT gateway (create mode). false (default) = local NAT. true = zero NAT
    gateways; the private default route (0.0.0.0/0) points at the TGW. Requires
    transit_gateway_id.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.centralized_egress || var.transit_gateway_id != ""
    error_message = "centralized_egress requires transit_gateway_id — there is nothing to route the default egress to without a transit gateway."
  }

  # adopt mode participates in a VPC it does not own, so this create-mode lever has nothing
  # to act on — reject the combination rather than silently ignoring it.
  validation {
    condition     = var.network_mode != "adopt" || !var.centralized_egress
    error_message = "centralized_egress is a create-mode lever and does not apply when network_mode = adopt — the VPC owner runs egress for an adopted VPC."
  }
}

variable "max_azs" {
  description = "Maximum number of availability zones to use"
  type        = number
  default     = 3
}

variable "nat_gateways" {
  description = "Number of NAT gateways (1 for development, 2 for staging, 3 for production). Ignored under centralized_egress (0 NAT gateways)."
  type        = number
  default     = 1
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch (create mode; the owner logs an adopted VPC)"
  type        = bool
  default     = false
}

variable "enable_vpc_endpoints" {
  description = "Enable VPC endpoints for AWS services (create mode; the owner runs endpoints on an adopted VPC)"
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

# --- adopt-mode inputs ------------------------------------------------------
variable "adopt_vpc_id" {
  description = "VPC ID to adopt (adopt mode). Required when network_mode = adopt."
  type        = string
  default     = ""

  validation {
    condition     = var.network_mode != "adopt" || var.adopt_vpc_id != ""
    error_message = "adopt_vpc_id is required when network_mode = adopt."
  }

  # create builds its own VPC, so an adopt_* reference to a foreign VPC is meaningless
  # there — reject it rather than silently ignoring it.
  validation {
    condition     = var.network_mode != "create" || var.adopt_vpc_id == ""
    error_message = "adopt_vpc_id is an adopt-mode input and does not apply when network_mode = create — create builds its own VPC, so leave it empty."
  }
}

variable "adopt_private_subnet_ids" {
  description = "Private subnet IDs in the adopted VPC (adopt mode). Required, non-empty, when network_mode = adopt."
  type        = list(string)
  default     = []

  validation {
    condition     = var.network_mode != "adopt" || length(var.adopt_private_subnet_ids) > 0
    error_message = "adopt_private_subnet_ids must be non-empty when network_mode = adopt."
  }

  # create builds its own subnets — reject adopt_* references under create mode.
  validation {
    condition     = var.network_mode != "create" || length(var.adopt_private_subnet_ids) == 0
    error_message = "adopt_private_subnet_ids is an adopt-mode input and does not apply when network_mode = create — leave it empty."
  }
}

variable "adopt_public_subnet_ids" {
  description = "Public subnet IDs in the adopted VPC (adopt mode). Empty is valid for a private-only cluster."
  type        = list(string)
  default     = []

  # create builds its own subnets — reject adopt_* references under create mode.
  validation {
    condition     = var.network_mode != "create" || length(var.adopt_public_subnet_ids) == 0
    error_message = "adopt_public_subnet_ids is an adopt-mode input and does not apply when network_mode = create — leave it empty."
  }
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
