################################################################################
# portal-hub — the management-account (hub) side of portal's IAM.
#
# Provisions the IRSA role portal's WORKER assumes (OIDC web identity, the portal
# worker ServiceAccount on the hub cluster) and the S3 bucket holding portal's
# OpenTofu state. The role can (a) sts:AssumeRole a portal-spoke role in any
# workload account — to mint EKS tokens + read EKS control planes for clusters
# portal manages — and (b) read/write the portal state bucket (the chart's
# objectStore, reached via IRSA so no static key sits at rest). A permissions
# boundary caps it: it can assume spokes + use its bucket, but never mint
# principals, touch org/account, or widen its own ceiling.
#
# Applied after the management (hub) EKS cluster exists (it takes that cluster's
# OIDC provider as input), alongside fleet-hub.
################################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  role_name  = var.role_name
  iam_path   = "/portal/"
  sa_subject = "system:serviceaccount:${var.namespace}:${var.service_account_name}"

  # IAM OIDC condition keys are the issuer URL WITHOUT the scheme; EKS reports it
  # WITH https://. Strip it so the var tolerates either form (a scheme in the key
  # silently breaks every assume).
  oidc_issuer_host = replace(var.oidc_issuer, "https://", "")
  ssm_prefix       = "/portal/${var.environment}/portal-hub"

  # The portal-spoke roles this worker may assume — any account, any env, under
  # the /portal/ path.
  spoke_role_arn_pattern = "arn:${local.partition}:iam::*:role/portal/*-portal-spoke"
  state_bucket_arn       = "arn:${local.partition}:s3:::${var.state_bucket_name}"

  tags = merge(var.tags, {
    Component = "portal-hub"
    Team      = var.team
  })
}

################################################################################
# Portal state bucket — the chart's objectStore (OpenTofu state, run logs, plans,
# config archives, modules). Holds portal's OpenTofu state for every managed
# account: the highest-value data in portal's blast radius. Hardened — versioned,
# SSE-KMS with a dedicated CMK, in-transit TLS enforced by bucket policy, server
# access logs to a private sibling bucket, public access blocked; S3 native
# locking.
################################################################################

resource "aws_kms_key" "portal_state" {
  description             = "portal ${var.environment} tofu state bucket encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.tags

  # Crown-jewel: this CMK decrypts the portal's tofu state. A tofu destroy of
  # portal-hub must never schedule it for deletion (which would render the state
  # bucket unreadable) — deliberate teardown removes this guard first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "portal_state" {
  name          = "alias/portal-${var.environment}-state"
  target_key_id = aws_kms_key.portal_state.key_id
}

resource "aws_s3_bucket" "portal_state" {
  bucket = var.state_bucket_name
  tags   = local.tags

  # Crown-jewel: this bucket holds the portal's tofu state. A tofu destroy of
  # portal-hub must never delete it — a deliberate teardown removes this guard first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "portal_state" {
  bucket = aws_s3_bucket.portal_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Versioning keeps every prior state as a noncurrent object; without expiry they
# accumulate forever. Keep the 10 most recent noncurrent versions unconditionally
# (recent-rollback safety), and expire the rest after 90 days. Aborted multipart
# uploads (interrupted state writes) are swept after 7 days.
resource "aws_s3_bucket_lifecycle_configuration" "portal_state" {
  bucket     = aws_s3_bucket.portal_state.id
  depends_on = [aws_s3_bucket_versioning.portal_state]

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "portal_state" {
  bucket = aws_s3_bucket.portal_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.portal_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "portal_state" {
  bucket                  = aws_s3_bucket.portal_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "portal_state" {
  bucket = aws_s3_bucket.portal_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.portal_state.arn,
        "${aws_s3_bucket.portal_state.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_logging" "portal_state" {
  bucket        = aws_s3_bucket.portal_state.id
  target_bucket = aws_s3_bucket.portal_state_logs.id
  target_prefix = "state-access/"
}

# Access-log sink for the state bucket. Private, its own TLS deny, and grants
# only the S3 logging service principal PutObject for this source bucket.
resource "aws_s3_bucket" "portal_state_logs" {
  bucket = "${var.state_bucket_name}-logs"
  tags   = local.tags

  lifecycle {
    precondition {
      condition     = length("${var.state_bucket_name}-logs") <= 63
      error_message = "log bucket ${var.state_bucket_name}-logs exceeds S3's 63-character limit; shorten state_bucket_name."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "portal_state_logs" {
  bucket                  = aws_s3_bucket.portal_state_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "portal_state_logs" {
  bucket = aws_s3_bucket.portal_state_logs.id
  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 on the log target keeps log delivery simple (no per-object kms
      # cost); access-log records carry no marginal value warranting a CMK.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "portal_state_logs" {
  bucket = aws_s3_bucket.portal_state_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3ServerAccessLogging"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.portal_state_logs.arn}/*"
        Condition = {
          ArnLike      = { "aws:SourceArn" = aws_s3_bucket.portal_state.arn }
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.portal_state_logs.arn,
          "${aws_s3_bucket.portal_state_logs.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

################################################################################
# Permissions boundary — the ceiling for the hub worker role. Allows only the
# assume + state surface, then hard-denies the escalation vectors and any
# self-widening.
################################################################################

resource "aws_iam_policy" "hub_boundary" {
  name        = "${var.environment}-portal-hub-boundary"
  path        = local.iam_path
  description = "Permissions boundary ceiling for the portal hub worker role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WorkerCeiling"
        Effect = "Allow"
        Action = [
          "sts:AssumeRole",
          "sts:GetCallerIdentity",
          "s3:*",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "logs:*",
          "tag:GetResources",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyEscalation"
        Effect = "Deny"
        Action = [
          "organizations:*",
          "account:*",
          "iam:*",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.tags
}

################################################################################
# The hub worker role — assumed by the portal worker pod via IRSA (OIDC web
# identity, the portal worker ServiceAccount). Carries the boundary.
################################################################################

data "aws_iam_policy_document" "hub_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = [local.sa_subject]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hub" {
  name                 = local.role_name
  path                 = local.iam_path
  assume_role_policy   = data.aws_iam_policy_document.hub_trust.json
  permissions_boundary = aws_iam_policy.hub_boundary.arn
  description          = "IRSA role the portal worker assumes to manage tenant accounts' EKS clusters"
  tags                 = local.tags
}

resource "aws_iam_role_policy" "hub" {
  name = "hub"
  role = aws_iam_role.hub.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Cross-account: assume a portal-spoke role in any workload account (to
        # mint EKS tokens + describe that account's clusters).
        Sid      = "AssumeSpokeRoles"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = local.spoke_role_arn_pattern
      },
      {
        # The portal state bucket — the chart's objectStore via IRSA (object rw +
        # list; HeadBucket maps to s3:ListBucket). The bucket is created here, so
        # no CreateBucket grant is needed.
        Sid    = "PortalState"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
      },
    ]
  })
}

################################################################################
# SSM — the chart/operator discover the worker role + state bucket
# (/portal/<env>/portal-hub/*).
################################################################################

resource "aws_ssm_parameter" "hub_role_arn" {
  name  = "${local.ssm_prefix}/hub_role_arn"
  type  = "String"
  value = aws_iam_role.hub.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "state_bucket" {
  name  = "${local.ssm_prefix}/state_bucket"
  type  = "String"
  value = aws_s3_bucket.portal_state.bucket
  tags  = local.tags
}
