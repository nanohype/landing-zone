variable "environment" {
  description = "Environment name — for this fleet-wide component, the token of the shared-services instance (e.g. shared). Used in the SSM discovery paths and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring.
# The provider carries the region; this component names no region-qualified resources.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "organization_id" {
  description = <<-EOT
    The AWS Organizations id (o-xxxxxxxxxx) that scopes cross-account alarm publishing. The
    topic policies and the alert CMK admit the CloudWatch service principal under an
    aws:SourceOrgID condition equal to this value, so exactly the accounts in this org — and no
    external account — can publish alarms to the central topics, with no per-account grant to
    maintain as the fleet grows.
  EOT
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must be an AWS Organizations id of the form o-xxxxxxxxxx (o- followed by 10-32 lowercase alphanumerics)."
  }
}

variable "name_prefix" {
  description = "Prefix for the fleet-wide resource names (topics, key alias). Fleet-wide, not per-environment — one topic set serves the whole fleet."
  type        = string
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.name_prefix))
    error_message = "name_prefix must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

variable "alert_email_endpoints" {
  description = "Fleet on-call email addresses subscribed to the critical and warning topics. Empty leaves the topics unsubscribed (wire a pager/ChatOps integration out of band)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
