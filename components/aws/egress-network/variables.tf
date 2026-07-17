variable "environment" {
  description = "Environment name (development, staging, production, hub)"
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

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

# --- Egress VPC address space -------------------------------------------------
variable "egress_vpc_cidr" {
  description = <<-EOT
    CIDR block for the egress hub VPC. This is dedicated infrastructure address space, NOT
    workload space — it must sit OUTSIDE the org workload supernet (spoke_supernet_cidr) so
    it never overlaps a spoke drawn from the org IPAM pools, which would break transit
    gateway routing. Carrier-grade NAT space (100.64.0.0/10, RFC 6598) is the recommended
    home; a /24 is plenty for an egress hub (a handful of NAT gateways and TGW-attachment
    ENIs). Subnets are carved to /28 regardless of the base size.
  EOT
  type        = string
  default     = "100.64.0.0/24"

  # Subnets are carved to a fixed /28 (28 - base_prefix newbits). A base between /16 and /24
  # keeps the newbits in a sane range and leaves room for public + NAT-facing private tiers
  # across max_azs zones. A shorter base wastes a large block on infra; a longer one cannot
  # carve /28 subnets (AWS's minimum).
  validation {
    condition     = tonumber(split("/", var.egress_vpc_cidr)[1]) >= 16 && tonumber(split("/", var.egress_vpc_cidr)[1]) <= 24
    error_message = "egress_vpc_cidr must have a prefix length between /16 and /24 — subnets are carved to /28, so a longer base cannot fit them and a shorter one over-allocates infra space."
  }
}

variable "spoke_supernet_cidr" {
  description = <<-EOT
    The org workload supernet every spoke VPC is drawn from — org-networking's IPAM
    top-level CIDR (10.0.0.0/8 by default). The egress hub adds a return route for this
    range (spoke_supernet_cidr -> TGW) to its public route tables so NAT-translated return
    traffic finds its way back to the originating spoke through the transit gateway. It also
    bounds the egress_vpc_cidr non-overlap check (see checks.tf).
  EOT
  type        = string
  default     = "10.0.0.0/8"

  # Shape guard: the return route and the overlap check both split and mask this value, so a
  # non-CIDR string would otherwise blow up mid-expression with a raw function error. cidrnetmask
  # only succeeds on a valid IPv4 CIDR, so this rejects a malformed value at validation time
  # with a clear message before any downstream expression touches it.
  validation {
    condition     = can(cidrnetmask(var.spoke_supernet_cidr))
    error_message = "spoke_supernet_cidr must be a valid IPv4 CIDR block (e.g. 10.0.0.0/8)."
  }
}

# --- Topology / egress --------------------------------------------------------
variable "max_azs" {
  description = "Maximum number of availability zones to spread the egress subnets across"
  type        = number
  default     = 3
}

variable "nat_gateways" {
  description = <<-EOT
    Number of NAT gateways for internet egress. Must be either 1 (a single shared NAT
    gateway — lowest cost, no per-AZ redundancy) or max_azs (one NAT gateway per zone — full
    HA). An in-between count is not supported: the VPC module ties NAT-gateway count to
    subnet count, so it builds one shared NAT or one per AZ, never an arbitrary number. A
    central egress hub typically wants per-AZ NAT for HA. The value equals the number of NAT
    gateways actually deployed.
  EOT
  type        = number
  default     = 1

  # The upstream terraform-aws-modules/vpc module derives NAT-gateway count from
  # single_nat_gateway (1) or one_nat_gateway_per_az (length(azs)) — there is no input for an
  # arbitrary count, and each private route table routes to nat[subnet_index]. A value like 2
  # with max_azs = 3 cannot be honored; left unguarded it silently plans max_azs gateways.
  # Reject it here so the mismatch surfaces at plan with a clear message instead of a silent
  # cost/behavior surprise.
  validation {
    condition     = var.nat_gateways == 1 || var.nat_gateways == var.max_azs
    error_message = "nat_gateways must be 1 (a single shared NAT gateway) or equal to max_azs (one NAT gateway per zone). terraform-aws-modules/vpc couples NAT-gateway count to subnet count, so an in-between value like 2 with max_azs = 3 cannot be built and would otherwise silently plan max_azs gateways. Choose 1 for cost or max_azs for per-AZ HA."
  }
}

variable "transit_gateway_id" {
  description = <<-EOT
    The org transit gateway this egress hub attaches to. Owned by org-networking (management
    account) and RAM-shared to this account; the hub attaches its NAT-facing private subnets
    to it. The static 0.0.0.0/0 route that steers every spoke's default egress at this
    attachment is created by org-networking (the TGW owner) — a TGW participant cannot write
    the owner's route tables (see README).
  EOT
  type        = string

  validation {
    condition     = can(regex("^tgw-[0-9a-f]+$", var.transit_gateway_id))
    error_message = "transit_gateway_id must be a transit gateway ID (tgw-...)."
  }
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch for the egress hub (egress traffic visibility)."
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
