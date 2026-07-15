variable "environment" {
  description = "Environment name (dev, staging, production)."
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
  description = "AWS region."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the incident-response Platform tenant runs. Matches the Platform CR's metadata.namespace (typically tenants-protohype)."
  type        = string
  default     = "tenants-protohype"
}

variable "service_account" {
  description = "Kubernetes ServiceAccount name incident-response's chart binds to. Matches the chart's serviceaccount.yaml output and the Platform CR's spec.irsa.serviceAccount."
  type        = string
  default     = "incident-response"
}

variable "deletion_protection" {
  description = "Enable deletion protection on the DynamoDB tables. Always true in production."
  type        = bool
  default     = true
}

variable "point_in_time_recovery" {
  description = "Enable PITR on the DynamoDB tables. Always true in production."
  type        = bool
  default     = true
}

variable "audit_ttl_days" {
  description = "Per-row TTL for the audit DDB table. Items past this age are reaped automatically."
  type        = number
  default     = 366
}

variable "identity_cache_ttl_seconds" {
  description = "Per-row TTL for the identity-cache DDB table. Workforce-directory lookups cached for this many seconds before re-resolving."
  type        = number
  default     = 3600
}

variable "sqs_visibility_timeout_seconds" {
  description = "SQS visibility timeout for the incident-events queue. incident-response's processor uses 300s per its SqsConsumer config."
  type        = number
  default     = 300
}

variable "sqs_message_retention_seconds" {
  description = "SQS retention before automatic deletion."
  type        = number
  default     = 1209600 # 14 days
}

variable "sqs_max_receive_count" {
  description = "Number of unsuccessful receives before SQS moves the message to the DLQ."
  type        = number
  default     = 3
}

variable "team" {
  description = "Owning team for this component (drives tagging + ArgoCD AppProject scope)."
  type        = string
  default     = "protohype"
}

variable "tags" {
  description = "Additional tags merged into every resource."
  type        = map(string)
  default     = {}
}
