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
  description = "S3 bucket holding the vended clusters' OpenTofu state (provider-opentofu backend)"
  type        = string
  default     = "nanohype-eks-fleet-tfstate"
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
