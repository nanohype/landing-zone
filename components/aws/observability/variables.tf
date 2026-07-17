# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "environment" {
  description = "Environment name (development, staging, production)"
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

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (for CloudWatch metrics)"
  type        = string
}

variable "alert_email_endpoints" {
  description = "Email addresses for SNS alerts"
  type        = list(string)
  default     = []
}

variable "enable_cluster_alarms" {
  description = "Enable EKS CloudWatch alarms"
  type        = bool
  default     = true
}

variable "enable_dashboard" {
  description = "Enable CloudWatch dashboard"
  type        = bool
  default     = true
}

variable "alarm_config" {
  description = "Alarm thresholds configuration"
  type = object({
    cpu_utilization_threshold    = number
    memory_utilization_threshold = number
    node_not_ready_period        = number
    api_server_error_threshold   = number
    api_server_latency_threshold = number
  })
  default = {
    cpu_utilization_threshold    = 80
    memory_utilization_threshold = 80
    node_not_ready_period        = 300
    api_server_error_threshold   = 5
    api_server_latency_threshold = 3000
  }
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
