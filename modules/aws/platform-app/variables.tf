variable "app_name" {
  description = "Single-tenant app name (e.g. incident-response). Composes the env-first resource grammar: the app-access managed policy is <environment>-<app_name>-app-access and the operator-reconciled tenant role is <environment>-<app_name>-tenant."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.app_name))
    error_message = "app_name must be a lowercase RFC-1123-style label (letters, digits, hyphens; no leading/trailing hyphen)."
  }
}

variable "environment" {
  description = "Environment name (development, staging, production). Prefixes every derived name so the grammar stays env-first."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }

  # Guard the seam that composes environment with app_name: an app_name that
  # already carries the environment token doubles it (<env>-<env>-...) in the
  # policy and role names. app_name is a fixed literal per component today, so
  # this is a regression tripwire rather than a caller-facing constraint.
  validation {
    condition     = var.app_name != var.environment && !startswith(var.app_name, "${var.environment}-")
    error_message = "app_name must not repeat the environment token: an app_name equal to or prefixed with '<environment>-' composes into a doubled '<env>-<env>-...' name."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the app's Platform tenant runs in. Matches the Platform CR's metadata.namespace."
  type        = string
}

variable "service_account" {
  description = "Kubernetes ServiceAccount name the app's chart binds to. Matches the chart's serviceaccount.yaml and the Platform CR's spec.irsa.serviceAccount."
  type        = string
}

variable "policy_statements" {
  description = "The app's substrate IAM statements (DynamoDB, SQS, S3, KMS, SES, Secrets Manager, CloudWatch, etc.). Wrapped into the <environment>-<app_name>-app-access managed policy. Bedrock invoke is NOT included here — that is operator territory, clamped by Platform.spec.identity.allowedModels."
  type        = any
}

variable "tags" {
  description = "Tags applied to the managed policy and the Pod Identity association."
  type        = map(string)
  default     = {}
}
