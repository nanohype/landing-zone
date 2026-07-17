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
  description = "AWS region"
  type        = string
}

variable "portal_role_arn" {
  description = "ARN of the management-account portal worker role allowed to assume this unwedge role (the only trusted principal — portal's break-glass force-unwedge path). Distinct from fleet-vend's hub trust on purpose: vending stays the hub's, teardown-of-a-wedge is portal's, and the vend role's trust never widens."
  type        = string
}

variable "external_id" {
  description = "sts:ExternalId portal must present when assuming the unwedge role (confused-deputy guard; not a secret)"
  type        = string
  default     = "eks-fleet-unwedge"
}

variable "team" {
  description = "Owning team tag"
  type        = string
  default     = "platform"
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
