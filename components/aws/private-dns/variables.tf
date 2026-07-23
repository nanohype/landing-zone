variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string

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

variable "dns_mode" {
  description = <<-EOT
    create — this account owns private DNS: it builds private hosted zone(s) associated with its
    own VPC (the default). This is the single-account path — a startup climbing the maturity ladder
    that wants an internal service domain, with no cross-account sharing.

    adopt — this account participates in private DNS it does not own: it associates a Route53
    Profile shared to it over RAM by a shared-dns owner, so every zone the Profile carries resolves
    in this VPC. This is the multi-account path — a workload account under an org-level shared-dns.

    Both modes take vpc_id and re-export dns_mode so a consumer can tell which shape it got.
  EOT
  type        = string
  default     = "create"

  validation {
    condition     = can(regex("^(create|adopt)$", var.dns_mode))
    error_message = "dns_mode must be exactly \"create\" or \"adopt\"."
  }

  # Cross-mode contract enforced on each field's own variable: private_zones rejects adopt,
  # profile_id rejects create. Anchoring both here would form a validation cycle.
}

variable "vpc_id" {
  description = "The VPC this account owns. In create mode the private zones are associated with it; in adopt mode the shared Profile is associated with it. Either way, a private zone or Profile association is inert unless this VPC has DNS resolution enabled — the preflight asserts it."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id (vpc-...)."
  }
}

# --- create-mode inputs -----------------------------------------------------

variable "private_zones" {
  description = <<-EOT
    Private hosted zone names to create and associate with this account's own VPC (create mode),
    e.g. ["internal.mystartup"]. external-dns writes service records into these; they resolve
    inside the VPC. At least one is required in create mode.
  EOT
  type        = list(string)
  default     = []

  # adopt mode does not own zones — it associates a Profile whose zones live in the shared-dns
  # owner. Reject rather than silently ignore.
  validation {
    condition     = var.dns_mode != "adopt" || length(var.private_zones) == 0
    error_message = "private_zones is a create-mode input and does not apply when dns_mode = adopt — the zones live in the shared-dns owner behind the Profile."
  }

  # create mode with no zones does nothing. Fail at variable evaluation, not silently.
  validation {
    condition     = var.dns_mode != "create" || length(var.private_zones) > 0
    error_message = "private_zones must declare at least one zone when dns_mode = create — a create-mode private-dns with no zones is a no-op."
  }

  validation {
    condition     = alltrue([for z in var.private_zones : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$", z))])
    error_message = "each private_zones entry must be a valid DNS name (lowercase labels, dot-separated)."
  }
}

# --- adopt-mode inputs ------------------------------------------------------

variable "profile_id" {
  description = "The Route53 Profile ID shared to this account over RAM by the shared-dns owner (adopt mode). Resolved from shared-dns's profile_id output or its SSM parameter. Empty in create mode."
  type        = string
  default     = ""

  # create mode owns its zones directly — a Profile id has nothing to act on. Reject.
  validation {
    condition     = var.dns_mode != "create" || var.profile_id == ""
    error_message = "profile_id is an adopt-mode input and does not apply when dns_mode = create — create mode owns its private zones directly, without a Profile."
  }

  # adopt mode has nothing to associate without it.
  validation {
    condition     = var.dns_mode != "adopt" || can(regex("^rp-[0-9a-z]+$", var.profile_id))
    error_message = "profile_id is required and must be a Route53 Profile id (rp-...) when dns_mode = adopt."
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
