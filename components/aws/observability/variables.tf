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

variable "observability_mode" {
  description = <<-EOT
    create — this component owns its alert delivery: it builds its own severity SNS topics,
    their CMK, and their policies, and points its alarms at them (the default).

    adopt — this component participates in fleet-wide alert delivery it does not own. It builds
    no topics: it points the same alarms at the central topics shared-observability owns
    (adopt_topic_arns) and re-exports them through the same sns_topic_arns output, so a consumer
    wires against one interface either way. Alarm definitions stay local in both modes.
  EOT
  type        = string
  default     = "create"

  validation {
    condition     = can(regex("^(create|adopt)$", var.observability_mode))
    error_message = "observability_mode must be exactly \"create\" or \"adopt\"."
  }
}

variable "adopt_topic_arns" {
  description = "Central alert topic ARNs by severity (critical/warning/info), from shared-observability's sns_topic_arns output. Required in adopt mode; the alarms publish here instead of to local topics."
  type        = map(string)
  default     = {}

  validation {
    condition     = var.observability_mode != "adopt" || alltrue([for sev in ["critical", "warning", "info"] : can(var.adopt_topic_arns[sev])])
    error_message = "adopt_topic_arns must carry critical, warning, and info ARNs when observability_mode = adopt."
  }

  # create builds its own topics, so an adopt reference to foreign topics is meaningless there.
  validation {
    condition     = var.observability_mode != "create" || length(var.adopt_topic_arns) == 0
    error_message = "adopt_topic_arns is an adopt-mode input and does not apply when observability_mode = create — leave it empty."
  }
}

variable "alert_email_endpoints" {
  description = "Email addresses for SNS alerts (create mode only — in adopt mode, subscriptions belong to the central topics shared-observability owns)."
  type        = list(string)
  default     = []

  # adopt mode publishes to central topics it does not own; subscribing pagers to them is the
  # owner's job. Reject the combination rather than silently ignoring it.
  validation {
    condition     = var.observability_mode != "adopt" || length(var.alert_email_endpoints) == 0
    error_message = "alert_email_endpoints is a create-mode lever — in adopt mode the central topics' subscriptions are owned by shared-observability, so leave it empty."
  }
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
