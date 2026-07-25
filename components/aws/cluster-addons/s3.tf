################################################################################
# Addon S3 Buckets
#
# Teardown posture, stated on every bucket rather than inherited from a module
# default that a version bump could change: force_destroy in development always,
# and elsewhere only when var.force_destroy_buckets has been applied. That covers
# velero, loki, tempo and argo-workflows uniformly.
#
# A still-populated bucket fails BucketNotEmpty, which halts a reverse teardown with
# the cluster, VPC and NAT gateways standing and billing — so a bucket that refuses
# to be destroyed does not protect the cluster, it strands it.
#
# Velero is included, which is worth stating plainly because it holds the cluster's
# restore points. A cluster here is agent-managed and often short-lived: eks-fleet
# vends spokes with a ttlDays and a hub reaper deletes them on expiry, so a spoke's
# own backups are not meant to outlive it. Where they should, velero_backup_policy
# copies the recovery points into the central vault in the backup account's DR
# region — and then emptying this bucket is not a loss. That is the mechanism for
# durable cluster backups; refusing to delete a local copy never was.
#
# What keeps the opt-in honest is that force_destroy only takes effect once an apply
# has landed it in state, so permitting a destroy and performing one are necessarily
# two separate acts. There is no single command that empties a populated bucket in an
# environment that has not already said yes.
################################################################################

locals {
  # Cluster-state backups are the one thing in this repo the central backup substrate does
  # not reach. AWS Backup has no EKS resource type, so it cannot capture Kubernetes objects
  # under any tagging — Velero is the only thing that does, and its restore points land in
  # this bucket, in the same account and region as the cluster they protect. That is exactly
  # the shape components/aws/shared-backup exists to fix for tenant datastores: "a backup
  # that lives only in the account it protects is one account event away from being gone
  # with the thing it protected."
  #
  # Setting velero_backup_policy to a plan key in the backup component brings this bucket
  # into that substrate — the plan copies its recovery points to the central vault in the
  # backup account's DR region — reusing what already exists rather than building a second
  # mechanism. Default empty, so nothing changes for an operator who has not opted in and
  # no backup cost appears unannounced.
  #
  # The tag is withheld unless versioning is on, for the same reason as tenant-substrate's
  # object stores: AWS Backup requires S3 Versioning, so a tagged unversioned bucket is
  # selected and then fails every job, reading as covered while unprotected.
  velero_backup_enabled = var.velero_backup_policy != ""

  # Teardown gate for every bucket in this file, velero included. Development is
  # unconditional; elsewhere it is opt-in. See var.force_destroy_buckets.
  bucket_force_destroy = var.environment == "development" || var.force_destroy_buckets
  velero_tags          = local.velero_backup_enabled ? merge(local.tags, { BackupPolicy = var.velero_backup_policy }) : local.tags

  # Longest TTL any Velero schedule sets, mirrored from
  # eks-gitops/addons/operations/velero/values.yaml — `weekly` carries
  # ttl: 2160h, and no per-environment values file overrides either schedule.
  # This is the number to change here when that one changes there.
  velero_longest_schedule_ttl_days = 90

  # The bucket's own expiry is only a backstop behind Velero's TTL, so it has to
  # outlast it. Derived rather than written as a literal: if these two numbers can
  # drift, they will, and the failure mode is silent — S3 deletes an object while
  # Velero still advertises it as a valid restore point, so the loss surfaces at
  # restore time instead of at backup time.
  velero_backup_expiry_days = local.velero_longest_schedule_ttl_days + 30
}

# Velero backup storage (conditional)
module "velero_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"
  count   = var.velero_enabled ? 1 : 0

  bucket = "${local.bucket_prefix}-velero"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # Deleting restore points is never a side effect: in development, and elsewhere only
  # once var.force_destroy_buckets has been applied. Both are deliberate — a cluster
  # with a ttlDays is declared disposable, and its backups are disposable with it. If
  # they should not be, velero_backup_policy puts the durable copy in the central vault
  # first, and then emptying this bucket costs nothing.
  force_destroy = local.bucket_force_destroy

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  # Versioning is off unless the bucket is opted into central backup, where AWS Backup
  # requires it. Velero manages its own object lifecycle, so versioning buys nothing on its
  # own and costs storage on every TTL delete.
  versioning = {
    enabled = local.velero_backup_enabled
  }

  lifecycle_rule = [
    {
      id      = "cleanup"
      enabled = true
      expiration = {
        days = local.velero_backup_expiry_days
      }
      # Only meaningful once versioning is on. Velero deletes an expired backup's objects,
      # which under versioning leaves delete markers and noncurrent versions behind; without
      # this they accumulate forever and are billed forever. Kept short because a noncurrent
      # version here is a superseded copy of something Velero already replaced — the durable
      # copy is the recovery point in the central vault, not the noncurrent object.
      noncurrent_version_expiration = {
        noncurrent_days = 7
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.velero_tags
}

# Publish the Velero backup bucket name to SSM so cluster-bootstrap can stamp it
# onto the ArgoCD cluster Secret as the `velero/backup-bucket` annotation, where
# the addons-velero ApplicationSet reads it as the backup + snapshot storage
# location. Published to SSM rather than passed as a terragrunt output because
# cluster-bootstrap also runs under the fleet-vend provider-opentofu path, which
# has no terragrunt dependency graph and resolves cross-component values through
# SSM — the same mechanism managed-monitoring and eval-runtime use. Gated on
# velero_enabled: a cluster without the backup bucket publishes nothing, and
# cluster-bootstrap leaves the annotation off (see its enable_velero_backup).
resource "aws_ssm_parameter" "velero_bucket" {
  count = var.velero_enabled ? 1 : 0

  name  = "/eks-agent-platform/${var.cluster_name}/cluster-addons/velero_bucket"
  type  = "String"
  value = module.velero_bucket[0].s3_bucket_id

  tags = local.tags
}

# Publish the Loki and Tempo bucket names to SSM so cluster-bootstrap can stamp them onto the
# ArgoCD cluster Secret as the observability/loki-bucket and observability/tempo-bucket
# annotations, where the addons-observability ApplicationSet injects them as the S3 backend for
# logs and traces. Both buckets already exist and their Pod Identity roles carry the S3 access
# (see loki_bucket / tempo_bucket above and pod-identity.tf), so only the names are published —
# the collectors resolve credentials from their Pod Identity association, no static-key Secret.
# Unconditional because the buckets are; cluster-bootstrap gates the annotation on
# enable_managed_monitoring, so a cluster without the monitoring stack keeps filesystem storage.
resource "aws_ssm_parameter" "loki_bucket" {
  name  = "/eks-agent-platform/${var.cluster_name}/cluster-addons/loki_bucket"
  type  = "String"
  value = module.loki_bucket.s3_bucket_id

  tags = local.tags
}

resource "aws_ssm_parameter" "tempo_bucket" {
  name  = "/eks-agent-platform/${var.cluster_name}/cluster-addons/tempo_bucket"
  type  = "String"
  value = module.tempo_bucket.s3_bucket_id

  tags = local.tags
}

# Loki log storage
module "loki_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-loki"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  force_destroy = local.bucket_force_destroy

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "cleanup"
      enabled = true
      expiration = {
        days = var.environment == "production" ? 90 : (var.environment == "staging" ? 30 : 14)
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tags
}

# Tempo trace storage
module "tempo_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-tempo"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  force_destroy = local.bucket_force_destroy

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "cleanup"
      enabled = true
      expiration = {
        days = var.environment == "production" ? 30 : 7
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tags
}

# Argo Workflows artifact storage (conditional)
module "argo_workflows_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"
  count   = var.argo_workflows_enabled ? 1 : 0

  bucket = "${local.bucket_prefix}-argo-workflows"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  force_destroy = local.bucket_force_destroy

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "cleanup"
      enabled = true
      expiration = {
        days = 30
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tags
}

# Publish the Argo Workflows artifact bucket name to SSM so cluster-bootstrap can
# stamp it onto the ArgoCD cluster Secret as the `argo-workflows/artifact-bucket`
# annotation, where the argo-workflows ApplicationSet reads it as the S3 artifact
# repository. Argo Workflows resolves its S3 credentials from the ambient chain via
# its Pod Identity association (see pod-identity.tf), so only the bucket name is published —
# no static-key Secret. Same seam Velero uses (SSM rather than a terragrunt output,
# because cluster-bootstrap also runs under the fleet-vend provider-opentofu path,
# which has no terragrunt dependency graph and resolves cross-component values
# through SSM). Gated on argo_workflows_enabled: a cluster without the bucket
# publishes nothing, and cluster-bootstrap leaves the annotation off (see its
# enable_argo_workflows).
resource "aws_ssm_parameter" "argo_workflows_bucket" {
  count = var.argo_workflows_enabled ? 1 : 0

  name  = "/eks-agent-platform/${var.cluster_name}/cluster-addons/argo_workflows_bucket"
  type  = "String"
  value = module.argo_workflows_bucket[0].s3_bucket_id

  tags = local.tags
}

################################################################################
# Bucket-name guard
#
# S3 rejects any name over 63 characters, and it rejects it at APPLY — halfway
# through creating the addons, with some buckets made and some not. Catch it at PLAN.
#
# The four buckets above are terraform-aws-modules/s3-bucket module blocks, and a
# module block cannot carry a lifecycle precondition. A `check` block only emits a
# warning, which is not a gate. So the assertion lives on a terraform_data resource,
# which creates nothing and fails the plan.
#
# Worst case today is 62 chars (production-platform-<12-digit-account>-ap-southeast-4-
# argo-workflows). The headroom is one character — a longer cluster_name is the
# thing that will break this, and this is what will tell you so.
################################################################################

resource "terraform_data" "bucket_name_guard" {
  lifecycle {
    precondition {
      condition = alltrue([
        for name in ["velero", "loki", "tempo", "argo-workflows"] :
        length("${local.bucket_prefix}-${name}") <= 63
      ])
      error_message = format(
        "S3 bucket names are limited to 63 characters and the prefix %q (%d chars) leaves too little room: %s. Shorten var.cluster_name.",
        local.bucket_prefix,
        length(local.bucket_prefix),
        join(", ", [
          for name in ["velero", "loki", "tempo", "argo-workflows"] :
          format("%s-%s (%d)", local.bucket_prefix, name, length("${local.bucket_prefix}-${name}"))
          if length("${local.bucket_prefix}-${name}") > 63
        ])
      )
    }
  }
}
