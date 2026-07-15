variable "environment" {
  description = "Environment name (dev, staging, production)"
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

variable "oidc_provider_arn" {
  description = "ARN of the hub EKS cluster's IAM OIDC provider"
  type        = string
}

variable "oidc_issuer" {
  description = "The hub EKS cluster's OIDC issuer URL (with or without https://; the scheme is stripped)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the portal worker ServiceAccount lives in"
  type        = string
  default     = "portal"
}

variable "service_account_name" {
  description = "The portal worker ServiceAccount name (the chart names it <release>-worker)"
  type        = string
  default     = "portal-worker"
}

variable "role_name" {
  description = "Name of the portal hub worker IRSA role"
  type        = string
  default     = "portal-worker"
}

variable "state_bucket_name" {
  description = "S3 bucket holding portal's OpenTofu state (the chart's objectStore.bucket)"
  type        = string
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
