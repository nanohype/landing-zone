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
  description = "EKS cluster name (used for naming)"
  type        = string
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "amg_account_access_type" {
  description = "Whether the Grafana workspace has CURRENT_ACCOUNT or ORGANIZATION account access"
  type        = string
  default     = "CURRENT_ACCOUNT"
}

variable "amg_authentication_providers" {
  description = "Grafana auth providers (AWS_SSO, SAML)"
  type        = list(string)
  default     = ["AWS_SSO"]
}

variable "amg_admin_user_ids" {
  description = "IAM Identity Center user IDs to grant Grafana ADMIN role"
  type        = list(string)
  default     = []
}

variable "amg_editor_user_ids" {
  description = "IAM Identity Center user IDs to grant Grafana EDITOR role"
  type        = list(string)
  default     = []
}

variable "amg_viewer_user_ids" {
  description = "IAM Identity Center user IDs to grant Grafana VIEWER role"
  type        = list(string)
  default     = []
}

variable "amp_alert_rules_enabled" {
  description = <<-EOT
    Install the AMP workspace's Alertmanager definition, routing every alert to the
    SNS topic named by amp_alert_sns_topic_arn.

    Off by default and refused without a destination: an Alertmanager whose route
    lands on a receiver with no configuration is a VALID config that silently
    discards every alert it accepts. It reports installed, evaluates correctly, and
    delivers nothing — the same looks-installed-delivers-nothing shape the alert
    topic policies are written to avoid.

    This installs the routing table only. Rules that fire alerts into it are a
    separate concern; this component provisions no rule group.
  EOT
  type        = bool
  default     = false
}

variable "amp_alert_sns_topic_arn" {
  description = <<-EOT
    SNS topic the AMP Alertmanager publishes to. Required when
    amp_alert_rules_enabled is set.

    Wire it to a severity topic the observability component publishes — it writes
    each tier's ARN to /eks-agent-platform/<cluster>/observability/alerts_<severity>_topic_arn,
    and exports the same set as sns_topic_arns.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = !var.amp_alert_rules_enabled || var.amp_alert_sns_topic_arn != ""
    error_message = "amp_alert_rules_enabled needs amp_alert_sns_topic_arn: an Alertmanager route to a receiver with no destination is a valid config that discards every alert, so the flag is refused without somewhere to send them."
  }

  validation {
    condition     = var.amp_alert_sns_topic_arn == "" || can(regex("^arn:aws[a-z-]*:sns:", var.amp_alert_sns_topic_arn))
    error_message = "amp_alert_sns_topic_arn must be an SNS topic ARN."
  }
}

variable "amp_alert_kms_key_arn" {
  description = <<-EOT
    CMK encrypting amp_alert_sns_topic_arn, if it carries one. The Alertmanager's
    publish role is granted kms:GenerateDataKey*/Decrypt on it, scoped by
    kms:ViaService to SNS.

    Empty means the topic uses SSE-SNS or no encryption. Getting this wrong fails
    the same silent way an absent receiver does: SNS accepts the publish and the
    encrypt is denied, so leave it set whenever the topic has a CMK.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.amp_alert_kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:", var.amp_alert_kms_key_arn))
    error_message = "amp_alert_kms_key_arn must be a KMS key ARN."
  }
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
