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

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "kms_deletion_window" {
  description = "KMS key deletion window in days"
  type        = number
  default     = 7
}

variable "enable_key_rotation" {
  description = "Enable automatic KMS key rotation"
  type        = bool
  default     = true
}

variable "secrets" {
  description = "Platform secrets to create. Sensitive: secret_string payloads must never surface in plan output, CLI diffs, or CI logs."
  type = map(object({
    description             = optional(string, "")
    recovery_window_in_days = optional(number, 30)
    secret_string           = optional(string, null)
    generate_random         = optional(bool, false)
    random_length           = optional(number, 32)
  }))
  default   = {}
  sensitive = true
}

variable "secret_path_prefix" {
  description = "SSM/Secrets Manager path prefix"
  type        = string
  default     = "/platform"
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
