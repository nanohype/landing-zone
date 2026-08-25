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

variable "oidc_provider_arn" {
  description = "EKS cluster OIDC provider ARN (from the cluster component)"
  type        = string
}

variable "oidc_issuer" {
  description = "EKS cluster OIDC issuer host, no scheme (oidc.eks.<region>.amazonaws.com/id/<id>)"
  type        = string
}

variable "operator_permissions_boundary_arn" {
  description = "Permissions-boundary ARN for the operator role. Fleet vends MUST set this to the vend/hub boundary ARN (published in SSM as /eks-fleet/<env>/fleet-vend/vend_permissions_boundary_arn or /eks-fleet/<env>/fleet-hub/hub_permissions_boundary_arn) — the fleet roles' CreateRole gate rejects an operator role that doesn't carry it. Empty (default) = no boundary (direct terragrunt applies, where the deploy role is not boundary-gated)."
  type        = string
  default     = ""
}

variable "bedrock_allowed_model_ids" {
  description = <<-EOT
    Foundation-model IDs (IAM resource globs) the tenant BASELINE grant may invoke.
    Each entry expands to the model's foundation-model ARN (AWS-owned, any region)
    plus the account's cross-region inference profiles that route to it, so
    bedrock:Invoke*/Converse* is scoped to exactly these models instead of
    Resource="*". Entries are model families, not version-pinned IDs (e.g.
    "anthropic.*"), so a new revision inside an allowed family stays covered without
    a policy change. This scopes the ATTACHED GRANT only; the tenant permissions
    boundary stays a broad ceiling by design (the privilege that matters is the
    grant, not the cap).

    An EMPTY list grants nothing: the BedrockInvoke statement is omitted entirely
    and tenant roles hold no Bedrock invoke permission. That is the reading a caller
    expects from an empty allowlist, and it is the safe direction for a list that
    can arrive empty by accident — one rendered from a set of Platform CRs is empty
    whenever that set is.

    To grant every model, write ["*"] in the list. The escape hatch stays
    expressible, and it moves to the call site where an auditor reading the config
    can see it, which an empty list never showed them.

    Scope notes: this is the fleet-wide baseline, so the default deliberately covers
    only Anthropic + Nova generation — a tenant needing another provider (Cohere
    Command, Llama, Mistral, AI21) gets it through a reviewed managed policy
    referenced in spec.identity.extraPolicyArns, not by widening this shared default. The expansion covers direct foundation
    models and system-defined cross-region inference profiles; application inference
    profiles, provisioned throughput, and custom/imported models are NOT matched —
    add their ARNs explicitly if a fork uses them.
  EOT
  type        = list(string)
  default     = ["anthropic.*", "amazon.nova-*"]
}

variable "bedrock_inference_profile_geos" {
  description = <<-EOT
    Geo-set prefixes the tenant baseline may invoke a cross-region inference
    profile through. Each allowlisted model family expands to one profile ARN per
    prefix, alongside its bare foundation-model ARN.

    Named rather than wildcarded because IAM matches text, not intent. A bare
    `inference-profile/*<family>` reads as "whatever the geo prefix is" and
    matches any profile whose NAME contains the family — including one created
    later with a name chosen to satisfy it.

    Defaults to us. alone: llm-policy names us-east-1 as the only preferred region
    and requires the geo prefix to match the deploy region, so a second entry here
    would name a prefix no workload in this estate can reach. Widen it in a fork
    that deploys elsewhere.
  EOT
  type        = list(string)
  default     = ["us."]

  validation {
    condition     = length(var.bedrock_inference_profile_geos) > 0
    error_message = "bedrock_inference_profile_geos must name at least one geo prefix; an empty list grants no inference-profile ARN at all, and every current Claude model is invoked through one."
  }

  validation {
    condition     = alltrue([for g in var.bedrock_inference_profile_geos : can(regex("^[a-z]+\\.$", g))])
    error_message = "each geo prefix is lowercase letters followed by a dot, e.g. \"us.\" or \"eu.\"."
  }
}

variable "team" {
  description = "Owning team tag"
  type        = string
  default     = "platform"
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "Full EKS cluster name this agent-platform substrate serves (e.g. development-platform). Keys the per-cluster SSM contract and the tenant/session role names the operator mints."
  type        = string
}

variable "data_kms_key_arn" {
  description = "KMS key ARN (the secrets component's data CMK) that encrypts the model-artifacts and eval-reports buckets at rest. Wired from dependency.secrets.outputs.kms_key_arn in the live layer; the tenant/session roles the operator mints already carry kms:Decrypt/GenerateDataKey (see the tenant ceiling grant in main.tf), and the key policy delegates to account IAM, so no key-policy edit is required for tenant access."
  type        = string
}

variable "artifacts_lifecycle_noncurrent_expiration_days" {
  description = "Delete non-current object versions in the model-artifacts and eval-reports buckets after N days."
  type        = number
  default     = 90
}

variable "artifacts_backup_policy" {
  description = <<-EOT
    BackupPolicy tag value for the model-artifacts and eval-reports buckets, naming a plan key
    in the backup component (e.g. "daily"). Empty (default) leaves both untagged and out of
    central backup.

    What the default costs you. Both buckets are versioned, and versioning is the whole
    durability story without this: it survives an overwrite or a delete of the current object,
    and nothing else. It does not survive deletion of the bucket, loss of the account, or loss
    of the region — and model-artifacts holds the sole copies of every tenant's fine-tuned
    adapters on this cluster while eval-reports holds the record of what scored what. Neither
    is regenerable from the substrate.

    Set it to bring both into the same durability substrate the tenant datastores use: the plan
    copies recovery points to the central vault in the backup account's DR region, so the
    artifacts survive the loss of the account that produced them. Billed — the backup itself,
    plus the noncurrent versions it retains alongside the lifecycle rule above.

    The AWS Backup S3 prerequisite is met by construction here: both buckets enable versioning
    unconditionally, so unlike the tenant object stores there is no per-bucket gate to apply.
  EOT
  type        = string
  default     = ""

  # A value matching no plan key selects nothing, so it would read as protected while being
  # ignored. This root cannot see the backup component's keys, so it asserts the shape only.
  validation {
    condition     = var.artifacts_backup_policy == "" || can(regex("^[a-z][a-z0-9-]*$", var.artifacts_backup_policy))
    error_message = "artifacts_backup_policy must be empty or a lowercase plan key (letters, digits, hyphens) matching a key in the backup component's backup_plans."
  }
}

variable "artifacts_access_logs_retention_days" {
  description = "Retention (days) for S3 server-access logs in the artifacts access-logs bucket."
  type        = number
  default     = 365
}

variable "force_destroy_buckets" {
  description = <<-EOT
    Allow this component's S3 buckets to be destroyed while they still hold objects, in any
    environment. Development already allows it unconditionally; this is the opt-in for
    everywhere else.

    It exists because a cluster here is an agent-managed, often short-lived thing — eks-fleet
    vends spokes with a ttlDays and a hub reaper that deletes them on expiry — so a teardown is
    an ordinary lifecycle event rather than an emergency. Without this, a reverse teardown of a
    non-development spoke wedges on BucketNotEmpty and leaves the cluster, VPC and NAT gateways
    standing and billing, which is the outcome the teardown existed to prevent.

    Deliberately two acts, not one flag: force_destroy has no effect until a successful apply
    lands it in state, so an operator (or an agent) must apply with this set and only then
    destroy. There is no single command that reaches a populated production bucket.

    What it exposes: model-artifacts holds the sole copies of every tenant's fine-tuned adapters
    on this cluster, and eval-reports the reports scoring them. Neither is regenerable from the
    substrate. Leave it false unless the cluster is genuinely disposable.
  EOT
  type        = bool
  default     = false
}
