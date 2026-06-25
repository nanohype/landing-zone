variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
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
  description = "Platform secrets to create"
  type = map(object({
    description             = optional(string, "")
    recovery_window_in_days = optional(number, 30)
    secret_string           = optional(string, null)
    generate_random         = optional(bool, false)
    random_length           = optional(number, 32)
  }))
  default = {}
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
