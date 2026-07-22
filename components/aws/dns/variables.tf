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

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

variable "dns_mode" {
  description = <<-EOT
    create — this component owns a public hosted zone: it builds the zone, its subdomain
    zones, DNS-validated ACM certificates, and optional DNSSEC signing (the default).

    adopt — this component references a public hosted zone it does not own (one created in
    another account or out of band). It builds nothing: it resolves the zone from
    adopt_zone_id via a read-only data source and re-exports its id / name servers through
    the same outputs, so a consumer wires against one interface either way. Certificate
    issuance and DNSSEC belong to whoever owns the zone, so those levers are create-only.
  EOT
  type        = string
  default     = "create"

  validation {
    condition     = can(regex("^(create|adopt)$", var.dns_mode))
    error_message = "dns_mode must be exactly \"create\" or \"adopt\"."
  }

  # The cross-mode contract (a field from the wrong side is a contradiction, not a no-op) is
  # enforced on each field's own variable below, referencing dns_mode one way — the create-mode
  # levers reject adopt mode, adopt_zone_id rejects create mode. Anchoring both halves here
  # would make dns_mode and the mode-specific variables reference each other in a cycle.
}

variable "domain_name" {
  description = "Primary domain name this component owns (create) or references (adopt), e.g. example.com. In adopt mode the resolved zone's name must equal this value — the adopt preflight asserts it."
  type        = string
}

# --- create-mode inputs -----------------------------------------------------

variable "subdomain_prefixes" {
  description = "Additional same-account subdomains to create zones for and delegate from the primary (e.g. [\"api\", \"app\"]). Create mode only."
  type        = list(string)
  default     = []

  # adopt mode references a zone it does not own — it cannot create or delegate subdomains
  # under it. Reject the combination rather than silently ignoring it.
  validation {
    condition     = var.dns_mode != "adopt" || length(var.subdomain_prefixes) == 0
    error_message = "subdomain_prefixes is a create-mode lever and does not apply when dns_mode = adopt — leave it empty for an adopted zone."
  }
}

variable "enable_dnssec" {
  description = "Enable DNSSEC signing on the primary hosted zone. Create mode only — signing belongs to the zone owner."
  type        = bool
  default     = false

  validation {
    condition     = var.dns_mode != "adopt" || var.enable_dnssec == false
    error_message = "enable_dnssec is a create-mode lever and does not apply when dns_mode = adopt — the zone owner signs the zone."
  }
}

variable "acm_certificates" {
  description = "Map of ACM certificates to create with DNS validation against the primary zone. Create mode only — DNS validation writes records into the zone, which only the owner can do."
  type = map(object({
    domain_name               = string
    subject_alternative_names = optional(list(string), [])
    wait_for_validation       = optional(bool, true)
  }))
  default = {}

  # DNS-validating a certificate writes a validation record into the zone. adopt mode does not
  # own the zone, so it cannot validate — certificates are issued where the account owns the
  # zone (see the per-account delegated-subdomain model). Reject rather than fail opaquely at
  # apply when the validation record write is denied.
  validation {
    condition     = var.dns_mode != "adopt" || length(var.acm_certificates) == 0
    error_message = "acm_certificates is a create-mode lever and does not apply when dns_mode = adopt — issue certificates in the account that owns the zone."
  }
}

# --- adopt-mode inputs ------------------------------------------------------

variable "adopt_zone_id" {
  description = "Route53 hosted zone ID to resolve and re-export (adopt mode). Empty in create mode."
  type        = string
  default     = ""

  # create mode builds its own zone, so an adopt_zone_id has nothing to act on — a value here
  # is a contradiction, not an override. Reject it.
  validation {
    condition     = var.dns_mode != "create" || var.adopt_zone_id == ""
    error_message = "adopt_zone_id is an adopt-mode input and does not apply when dns_mode = create — the component builds its own zone."
  }

  # adopt mode has nothing to resolve without it. Fail at variable evaluation with a clear
  # message rather than at the data source with a raw provider error.
  validation {
    condition     = var.dns_mode != "adopt" || var.adopt_zone_id != ""
    error_message = "adopt_zone_id is required when dns_mode = adopt — it names the existing zone to resolve and re-export."
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
