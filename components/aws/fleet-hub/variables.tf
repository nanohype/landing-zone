variable "environment" {
  description = "Environment name for the management hub (tags + SSM path)"
  type        = string
  default     = "management"

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

variable "oidc_provider_arn" {
  description = "OIDC provider ARN of the management (hub) EKS cluster — from the cluster component"
  type        = string
}

variable "oidc_issuer" {
  description = "OIDC issuer host of the hub cluster, no scheme (oidc.eks.<region>.amazonaws.com/id/<id>)"
  type        = string
}

variable "state_bucket_name" {
  description = <<-EOT
    S3 bucket holding the vended clusters' OpenTofu state (provider-opentofu
    backend). Unlike the repo's per-cluster/per-tenant buckets, this name carries
    NO account-id element by deliberate exception: it is a singleton in exactly one
    always-hub (management) account, so there is no per-account collision to guard
    against, and it is a cross-repo bootstrap contract — the eks-fleet
    provider-opentofu backend and rackctl's preflight resolve state against this
    name before any in-cluster SSM lookup is possible, so an account-qualified name
    would break discovery-free bootstrap. Global S3 uniqueness comes from the
    `nanohype-` org prefix; a fork rebrands that prefix rather than appending an
    account id.
  EOT
  type        = string
  default     = "nanohype-eks-fleet-tfstate"

  validation {
    condition     = length(var.state_bucket_name) >= 3 && length("${var.state_bucket_name}-logs") <= 63
    error_message = "state_bucket_name must be 3+ chars and leave room for the '-logs' access-log sibling within S3's 63-char limit."
  }
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
