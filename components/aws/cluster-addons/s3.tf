################################################################################
# Addon S3 Buckets
#
# Teardown posture, one line per bucket, stated rather than inherited from a
# module default that a version bump could change:
#
#   velero          force_destroy = false, always. Cluster backups.
#   loki, tempo     development only — telemetry, re-emitted by a running cluster.
#   argo-workflows  development only — workflow artifacts and logs.
#
# The development-only expression is the idiom at components/aws/cost/main.tf: a
# still-populated bucket fails BucketNotEmpty, which halts a reverse teardown
# with the cluster, VPC and NAT gateways standing and billing, and development is
# the only environment the teardown harnesses run in.
#
# prevent_destroy is not available here — a lifecycle block is not valid on a
# module block — so velero's protection is the explicit false below plus the
# absence of any override. If that ever needs to be a hard guarantee rather than
# a default, the bucket has to become a first-party aws_s3_bucket resource, the
# shape fleet-hub and portal-hub use for their crown-jewel state buckets.
################################################################################

locals {
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

  # Never force-destroyed, in any environment. This holds the cluster's restore
  # points; a teardown that empties it removes the thing that would have made the
  # teardown recoverable. A destroy here is meant to fail on BucketNotEmpty so
  # deleting backups stays a deliberate, separate act.
  force_destroy = false

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
        days = local.velero_backup_expiry_days
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tags
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

  force_destroy = var.environment == "development"

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

  force_destroy = var.environment == "development"

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

  force_destroy = var.environment == "development"

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
