variable "role_name" {
  description = "Name of the IAM role"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for the service account"
  type        = string
}

variable "service_account" {
  description = "Kubernetes service account name"
  type        = string
}

variable "policy_statements" {
  description = "IAM policy statements to attach inline"
  type = list(object({
    Effect   = string
    Action   = list(string)
    Resource = list(string)
  }))
  default = []
}

variable "managed_policy_arns" {
  description = "List of managed IAM policy ARNs to attach"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to the role"
  type        = map(string)
  default     = {}
}

variable "path" {
  description = "IAM path for the role (e.g. \"/eks-fleet/\" for cross-account fleet-vend gating). Default \"/\" = AWS root path."
  type        = string
  default     = "/"
}

variable "permissions_boundary" {
  description = "ARN of the permissions boundary to attach to the role. null = no boundary (the default)."
  type        = string
  default     = null
}
