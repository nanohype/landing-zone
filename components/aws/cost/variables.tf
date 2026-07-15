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

variable "monthly_budget_limit" {
  description = "Monthly budget limit in USD"
  type        = number
}

variable "budget_alert_thresholds" {
  description = "Percentage thresholds for budget alerts"
  type        = list(number)
  default     = [50, 80, 100, 120]
}

variable "budget_alert_emails" {
  description = "Email addresses for budget notifications"
  type        = list(string)
  default     = []
}

variable "enable_anomaly_detection" {
  description = "Enable AWS Cost Anomaly Detection"
  type        = bool
  default     = true
}

variable "anomaly_threshold" {
  description = "Dollar threshold for anomaly alerts"
  type        = number
  default     = 100
}

variable "enable_cur_report" {
  description = "Enable Cost & Usage Report (typically only one per account)"
  type        = bool
  default     = false
}

variable "cur_report_prefix" {
  description = "S3 prefix for CUR reports"
  type        = string
  default     = "cur"
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "enable_tenant_anomaly_detection" {
  description = "Enable per-tenant cost anomaly detection"
  type        = bool
  default     = false
}

variable "tenant_names" {
  description = "Set of tenant names for per-tenant anomaly monitoring"
  type        = set(string)
  default     = []
}

variable "tenant_anomaly_threshold" {
  description = "Dollar threshold for tenant anomaly alerts"
  type        = number
  default     = 100
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
