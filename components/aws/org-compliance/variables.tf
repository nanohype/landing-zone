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

variable "enable_cloudtrail" {
  description = "Enable CloudTrail"
  type        = bool
  default     = true
}

variable "enable_org_trail" {
  description = "Enable organization-wide trail (requires AWS Organizations)"
  type        = bool
  default     = true
}

variable "cloudtrail_s3_retention" {
  description = "Days to retain CloudTrail logs in S3 before expiration"
  type        = number
  default     = 2555
}

variable "enable_log_insights" {
  description = "Enable CloudTrail CloudWatch Logs delivery for Log Insights"
  type        = bool
  default     = true
}

variable "enable_config" {
  description = "Enable AWS Config"
  type        = bool
  default     = true
}

variable "enable_config_aggregator" {
  description = "Enable organization-level Config aggregator"
  type        = bool
  default     = false
}

variable "config_rules" {
  description = "Map of AWS Config managed rules to create"
  type = map(object({
    source_identifier = string
    input_parameters  = optional(map(string), {})
  }))
  default = {}
}

variable "conformance_packs" {
  description = "List of AWS Config conformance pack names to deploy"
  type        = list(string)
  default     = []
}

variable "organization_managed_rules" {
  description = <<-EOT
    AWS Config organization managed rules — a managed rule deployed from this management (or
    delegated-admin) account across every member account, so a check evaluates resources in
    the workload accounts, not just here. Regular config_rules above run only in this account;
    an org-managed rule is how a cross-account posture check (e.g. backup coverage of resources
    that live in workload accounts) is enforced org-wide. resource_types_scope narrows which
    resource types the rule evaluates; excluded_accounts opts specific accounts out.
  EOT
  type = map(object({
    rule_identifier      = string
    description          = optional(string, "")
    input_parameters     = optional(map(string), {})
    resource_types_scope = optional(list(string), [])
    excluded_accounts    = optional(list(string), [])
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
