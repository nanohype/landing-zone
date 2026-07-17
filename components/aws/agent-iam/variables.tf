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
    a policy change. Empty list = grant every model (Resource="*") — the explicit,
    auditable escape hatch. This scopes the ATTACHED GRANT only; the tenant
    permissions boundary stays a broad ceiling by design (the privilege that matters
    is the grant, not the cap).

    Scope notes: this is the fleet-wide baseline, so the default deliberately covers
    only Anthropic + Nova generation — a tenant needing another provider (Cohere
    Command, Llama, Mistral, AI21) gets it through its per-tenant app-access policy,
    not by widening this shared default. The expansion covers direct foundation
    models and system-defined cross-region inference profiles; application inference
    profiles, provisioned throughput, and custom/imported models are NOT matched —
    add their ARNs explicitly (or use the empty-list escape hatch) if a fork uses them.
  EOT
  type        = list(string)
  default     = ["anthropic.*", "amazon.nova-*"]
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

variable "artifacts_access_logs_retention_days" {
  description = "Retention (days) for S3 server-access logs in the artifacts access-logs bucket."
  type        = number
  default     = 365
}
