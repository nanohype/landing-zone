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

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "cluster_name" {
  description = "Name of the EKS cluster this environment's secrets serve. Uniform envcommon interface input; this component provisions no cluster-bound resources and does not consume it."
  type        = string
}

variable "kms_deletion_window" {
  description = "KMS key deletion window in days"
  type        = number
  default     = 7
}

variable "enable_key_rotation" {
  description = "Enable automatic KMS key rotation"
  type        = bool
  default     = true
}

variable "separate_logs_key" {
  description = <<-EOT
    Mint a second CMK for the log path instead of encrypting logs and data with one key.

    Shared (default, false): one key carries every service grant — Secrets Manager, CloudWatch
    Logs, and Bedrock's invocation-log delivery. `logs_kms_key_arn` and `kms_key_arn` are the
    same ARN. One key to rotate, one to audit, one bill.

    Separate (true): the log-path grants MOVE off the secrets key onto a second key aliased
    `<environment>-platform-logs`. The secrets key keeps only the account root and Secrets
    Manager; the logs key gets CloudWatch Logs and Bedrock. That is what buys the posture where
    a principal able to read operational logs cannot, by that grant, decrypt platform data —
    with one key there is no such boundary to hold, whatever a policy says.

    The grants MOVE rather than being copied, deliberately. A logs key that is separate but
    where the secrets key still admits `logs.<region>.amazonaws.com` would let a log group
    encrypt with either, which is the appearance of a boundary and none of the substance.

    The consequence of moving them is that a consumer still passing the secrets key where a log
    group expects one fails at `CreateLogGroup` rather than quietly encrypting logs under the
    data key — read `logs_kms_key_arn`, which is correct in both modes.

    Flip it per environment, not per fleet: separation is worth its second key where the log
    reader and the data reader are different people, and is overhead where they are the same
    one. It is not retroactive. Changing it re-points what NEW objects and log events are
    encrypted with; everything already written stays under the key that wrote it, and stays
    readable only to a principal that can still decrypt with that key.
  EOT
  type        = bool
  default     = false
}

variable "secrets" {
  description = "Platform secrets to create. Sensitive: secret_string payloads must never surface in plan output, CLI diffs, or CI logs."
  type = map(object({
    description             = optional(string, "")
    recovery_window_in_days = optional(number, 30)
    secret_string           = optional(string, null)
    generate_random         = optional(bool, false)
    random_length           = optional(number, 32)
  }))
  default   = {}
  sensitive = true
}

variable "secret_path_prefix" {
  description = "SSM/Secrets Manager path prefix"
  type        = string
  default     = "/platform"
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
