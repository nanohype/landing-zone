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

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "notification_emails" {
  description = "Email addresses for quota alert notifications"
  type        = list(string)
  default     = []
}

variable "quota_threshold_percent" {
  description = "Percentage threshold for quota alarms (0-100)"
  type        = number
  default     = 80
}

variable "monitored_quotas" {
  description = <<-EOT
    Service quotas to alarm on utilization.

    A quota can only be alarmed if AWS publishes a usage metric for it — Service
    Quotas returns that as `UsageMetric`, and it is empty for most quotas. There
    is no dimension set that makes an alarm work without one, so this component
    fails the plan rather than creating an alarm that can never leave
    INSUFFICIENT_DATA. Check before adding an entry:

        aws service-quotas get-service-quota \
          --service-code <svc> --quota-code <code> --query 'Quota.UsageMetric'
  EOT
  type = map(object({
    service_code = string
    quota_code   = string
    description  = string
  }))
  # Only quotas AWS publishes a usage metric for. Verified against the live API
  # in us-west-2: eips_per_region (ec2/L-0263D0A3), nat_gateways_per_az
  # (vpc/L-FE5A380F) and eks_clusters (eks/L-1194D53C) all return an empty
  # UsageMetric, so the alarms this component used to build for them could never
  # have fired. Their utilization has to come from somewhere else — a Cost
  # Explorer/Config view, or polling DescribeAccountAttributes — not CloudWatch.
  default = {
    vpc_per_region = {
      service_code = "vpc"
      quota_code   = "L-F678F1CE"
      description  = "VPCs per region"
    }
    lambda_concurrent = {
      service_code = "lambda"
      quota_code   = "L-B99A9384"
      description  = "Lambda concurrent executions"
    }
  }
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
