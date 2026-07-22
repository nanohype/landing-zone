variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string

  # Format contract, not a closed enum — matches every other component. Catches
  # empty/uppercase/typo'd values before they flow into resource names, tags, and SSM paths.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

# Uniform envcommon interface variable — every component declares it; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

variable "seed_vpc_id" {
  description = <<-EOT
    A VPC in THIS (owner) account used to seed the private hosted zones at creation. Route53
    requires every private hosted zone to be associated with a VPC in the same account that
    creates it — the zone cannot be created VPC-less. This is that VPC (the network-owner
    account's shared VPC, from shared-network). The zones are then attached to the Route53
    Profile, which propagates them to every consumer VPC that associates the shared Profile —
    so the seed VPC is a creation requirement, not the resolution path.
  EOT
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.seed_vpc_id))
    error_message = "seed_vpc_id must be a VPC id (vpc-...)."
  }
}

variable "private_zones" {
  description = <<-EOT
    Private hosted zone names this component owns and attaches to the Profile, e.g.
    ["internal.nanohype"]. external-dns in an adopting cluster writes service records into
    these; the Profile makes them resolve in every associated cluster VPC. At least one is
    required — a Profile with no zones shares nothing.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.private_zones) > 0
    error_message = "private_zones must declare at least one zone — a shared-dns with no zones is an orphan Profile."
  }

  validation {
    condition     = alltrue([for z in var.private_zones : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$", z))])
    error_message = "each private_zones entry must be a valid DNS name (lowercase labels, dot-separated)."
  }
}

variable "consumer_account_ids" {
  description = <<-EOT
    Workload account IDs that receive the Profile over AWS RAM. Each associates the shared
    Profile with its cluster VPC (via the private-dns component) to resolve the private zones.
    allow_external_principals stays false, so every id must be an org member.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.consumer_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "each consumer_account_ids entry must be a 12-digit AWS account id."
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
