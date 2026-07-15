variable "environment" {
  description = "Environment name"
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

################################################################################
# Transit Gateway
################################################################################

variable "enable_transit_gateway" {
  description = "Enable Transit Gateway"
  type        = bool
  default     = true
}

variable "tgw_asn" {
  description = "ASN for the Transit Gateway"
  type        = number
  default     = 64512
}

variable "tgw_default_route_table_association" {
  description = "Enable default route table association"
  type        = bool
  default     = true
}

variable "tgw_default_route_table_propagation" {
  description = "Enable default route table propagation"
  type        = bool
  default     = true
}

variable "ram_principals" {
  description = "List of account IDs or OU ARNs to share resources with"
  type        = list(string)
  default     = []
}

################################################################################
# IPAM
################################################################################

variable "enable_ipam" {
  description = "Enable VPC IPAM"
  type        = bool
  default     = true
}

variable "ipam_operating_regions" {
  description = "IPAM operating regions (defaults to var.region)"
  type        = list(string)
  default     = []
}

variable "ipam_top_level_cidr" {
  description = "Top-level CIDR for IPAM"
  type        = string
  default     = "10.0.0.0/8"
}

variable "ipam_pools" {
  description = "Map of environment sub-pools"
  type = map(object({
    cidr        = string
    description = string
    locale      = optional(string)
    tags        = optional(map(string), {})
  }))
  default = {}
}

################################################################################
# Route53 Resolver
################################################################################

variable "enable_resolver" {
  description = "Enable Route53 Resolver endpoints"
  type        = bool
  default     = false
}

variable "resolver_vpc_id" {
  description = "VPC ID for resolver endpoints (required when enable_resolver = true)"
  type        = string
  default     = ""
}

variable "resolver_subnet_ids" {
  description = "Subnet IDs for resolver endpoint ENIs"
  type        = list(string)
  default     = []
}

variable "resolver_rules" {
  description = "Map of Route53 Resolver forwarding rules"
  type = map(object({
    domain_name = string
    target_ips  = list(string)
    rule_type   = optional(string, "FORWARD")
  }))
  default = {}
}

################################################################################
# Common
################################################################################

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
