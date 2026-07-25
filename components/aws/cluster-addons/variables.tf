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
  description = "EKS cluster name"
  type        = string
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "velero_enabled" {
  description = "Enable Velero Pod Identity role and S3 bucket"
  type        = bool
  default     = true
}

variable "velero_backup_policy" {
  description = <<-EOT
    BackupPolicy tag value for the Velero bucket, naming a plan key in the backup component
    (e.g. "daily"). Empty (default) leaves the bucket untagged and out of central backup.

    Set it to bring cluster-state restore points into the same durability substrate the tenant
    datastores use: the plan copies recovery points to the central vault in the backup
    account's DR region, so a cluster's backups survive the loss of the account that produced
    them. Without it, Velero's restore points live only in the account and region of the
    cluster they protect.

    Setting this also enables S3 Versioning on the bucket, which AWS Backup requires for S3.
    Both are billed — the backup itself, and the noncurrent versions Velero's own TTL deletes
    leave behind (bounded to 7 days here).
  EOT
  type        = string
  default     = ""

  # A tag value that matches no plan key selects nothing, so it would read as protected while
  # being ignored — the same silent-coverage failure the versioning gate exists to prevent.
  # This cannot verify the key exists in the backup component (a separate root), so it only
  # asserts the shape the plan keys use.
  validation {
    condition     = var.velero_backup_policy == "" || can(regex("^[a-z][a-z0-9-]*$", var.velero_backup_policy))
    error_message = "velero_backup_policy must be empty or a lowercase plan key (letters, digits, hyphens) matching a key in the backup component's backup_plans."
  }
}

variable "opencost_enabled" {
  description = "Enable OpenCost Pod Identity role"
  type        = bool
  default     = true
}

variable "keda_enabled" {
  description = "Enable KEDA Pod Identity role"
  type        = bool
  default     = true
}

variable "argo_events_enabled" {
  description = "Enable Argo Events Pod Identity role"
  type        = bool
  default     = true
}

variable "argo_workflows_enabled" {
  description = "Enable Argo Workflows Pod Identity role and S3 bucket"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

variable "force_destroy_buckets" {
  description = <<-EOT
    Allow this component's S3 buckets to be destroyed while they still hold objects, in any
    environment. Development already allows it unconditionally; this is the opt-in for
    everywhere else, and it INCLUDES the Velero bucket.

    Velero is included because a cluster here is agent-managed and often short-lived — eks-fleet
    vends spokes with a ttlDays and a hub reaper deletes them on expiry — so a cluster's own
    restore points are not meant to outlive it by default. A backup that blocks the teardown of
    the disposable thing it was protecting is not protection, it is a stuck reaper and a running
    NAT gateway.

    Deliberately two acts, not one flag: force_destroy has no effect until a successful apply
    lands it in state, so allowing the destroy and performing it cannot be the same command.

    If cluster state needs to survive the cluster, that is what velero_backup_policy is for —
    it copies the recovery points to the central vault in the backup account's DR region, so
    emptying this bucket stops being lossy. Set that first if the restore points matter, then
    this.
  EOT
  type        = bool
  default     = false
}
