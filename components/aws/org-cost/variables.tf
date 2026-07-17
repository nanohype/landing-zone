variable "environment" {
  description = "Environment name"
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

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

variable "org_budget_limit" {
  description = "Organization-wide monthly budget limit in USD"
  type        = number
}

variable "budget_alert_thresholds" {
  description = "Percentage thresholds for budget alerts"
  type        = list(number)
  default     = [50, 80, 100, 120]
}

variable "budget_alert_emails" {
  description = "Email addresses for budget and anomaly notifications"
  type        = list(string)
  default     = []
}

variable "enable_anomaly_detection" {
  description = "Enable AWS Cost Anomaly Detection monitors"
  type        = bool
  default     = true
}

variable "anomaly_threshold" {
  description = "Dollar threshold for anomaly alerts"
  type        = number
  default     = 100
}

variable "enable_compute_optimizer" {
  description = "Enable AWS Compute Optimizer org-wide enrollment"
  type        = bool
  default     = true
}

variable "enable_savings_plans_alarm" {
  description = "Enable CloudWatch alarm for Savings Plans utilization"
  type        = bool
  default     = false
}

variable "enable_cur_export" {
  description = "Enable CUR 2.0 data export"
  type        = bool
  default     = false
}

variable "cost_categories" {
  description = "Map of cost categories to create"
  type = map(object({
    rule_version  = optional(string, "1")
    default_value = optional(string, "Other")
    rules = list(object({
      value = string
      rule = object({
        tags = object({
          key    = string
          values = list(string)
        })
      })
    }))
  }))
  default = {}
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
