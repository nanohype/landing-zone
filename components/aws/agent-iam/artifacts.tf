################################################################################
# Agent-platform artifact buckets
#
# The cluster-scoped artifact substrate the operator's Platform controller
# dereferences at startup: it resolves ArtifactsBucketName from SSM and calls
# ensureBucketPolicy() against the model-artifacts bucket on every Platform
# reconcile, while the eval-runner writes to the eval-reports bucket. These are
# the sole copies — one pair per cluster, shared across every Platform on it —
# and they live here beside the operator identity because agent-iam applies on
# the core chain (network -> cluster -> agent-iam) before ArgoCD brings the
# operator up, so the substrate exists before the first reconcile.
#
# The model-artifacts bucket policy is owned by the operator at runtime (it
# fetches then extends the policy with a per-tenant statement — see
# ensureBucketPolicy in nanohype/eks-agent-platform, platform_kms_s3.go), which
# is why this component blocks public access and grants the operator
# PutBucketPolicy but sets no policy of its own on that bucket. The eval-reports
# bucket is not operator-managed, so its TLS/KMS-enforce policy is set here.
#
# Naming is account+region-qualified (<cluster>-<account>-<region>-*) because
# S3's namespace is GLOBAL: two accounts — or one account in two regions —
# standing up a cluster of the same name must not collide. model-artifacts is
# the tightest cluster-scoped name in the org and sets the clusterName length
# cap (12 chars of base in us-west-2, fewer in a longer region); the
# preconditions below assert every derived name against S3's 63-char limit.
################################################################################

locals {
  model_artifacts_bucket = "${var.cluster_name}-${local.account_id}-${var.region}-model-artifacts"
  eval_reports_bucket    = "${var.cluster_name}-${local.account_id}-${var.region}-eval-reports"
  access_logs_bucket     = "${var.cluster_name}-${local.account_id}-${var.region}-access-logs"
  artifacts_ssm_prefix   = "/eks-agent-platform/${var.cluster_name}/model-artifacts"
}

################################################################################
# Access-logs bucket — S3 server-access log target for both data buckets.
# Separated so audit access can be scoped tightly (log readers never touch the
# data buckets). AES256, not the data CMK: S3 log delivery writes with the
# bucket's default encryption and does not assume a customer-managed key.
################################################################################

resource "aws_s3_bucket" "access_logs" {
  bucket = local.access_logs_bucket
  tags   = local.tags

  lifecycle {
    precondition {
      condition     = length(local.access_logs_bucket) <= 63
      error_message = "bucket ${local.access_logs_bucket} exceeds S3's 63-character limit; shorten var.cluster_name."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.artifacts_access_logs_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowLogDelivery"
      Effect    = "Allow"
      Principal = { Service = "logging.s3.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.access_logs.arn}/*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

################################################################################
# Model-artifacts bucket (LoRA / adapter / fine-tuned weights). SSE-KMS with the
# data CMK; server-access logged; versioned (an agent overwrite or a bad
# training run must not destroy the prior object). No bucket policy here — the
# operator owns it at runtime (see the header).
################################################################################

resource "aws_s3_bucket" "model_artifacts" {
  bucket = local.model_artifacts_bucket
  tags   = local.tags

  lifecycle {
    precondition {
      condition     = length(local.model_artifacts_bucket) <= 63
      error_message = "bucket ${local.model_artifacts_bucket} exceeds S3's 63-character limit; shorten var.cluster_name."
    }
  }
}

resource "aws_s3_bucket_logging" "model_artifacts" {
  bucket        = aws_s3_bucket.model_artifacts.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "model-artifacts/"
}

resource "aws_s3_bucket_versioning" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.data_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "model_artifacts" {
  bucket                  = aws_s3_bucket.model_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.artifacts_lifecycle_noncurrent_expiration_days
    }
  }

  rule {
    id     = "abort-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

################################################################################
# Eval-reports bucket. Written by the eval-runner (not per-tenant by the
# operator), so its policy is terraform-owned: deny non-TLS and unencrypted
# uploads. SSE-KMS with the data CMK; server-access logged; versioned.
################################################################################

resource "aws_s3_bucket" "eval_reports" {
  bucket = local.eval_reports_bucket
  tags   = local.tags

  lifecycle {
    precondition {
      condition     = length(local.eval_reports_bucket) <= 63
      error_message = "bucket ${local.eval_reports_bucket} exceeds S3's 63-character limit; shorten var.cluster_name."
    }
  }
}

resource "aws_s3_bucket_logging" "eval_reports" {
  bucket        = aws_s3_bucket.eval_reports.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "eval-reports/"
}

resource "aws_s3_bucket_versioning" "eval_reports" {
  bucket = aws_s3_bucket.eval_reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "eval_reports" {
  bucket = aws_s3_bucket.eval_reports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.data_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "eval_reports" {
  bucket                  = aws_s3_bucket.eval_reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "eval_reports" {
  bucket = aws_s3_bucket.eval_reports.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.artifacts_lifecycle_noncurrent_expiration_days
    }
  }

  rule {
    id     = "abort-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "eval_reports" {
  bucket = aws_s3_bucket.eval_reports.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.eval_reports.arn,
          "${aws_s3_bucket.eval_reports.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        # Deny an upload that explicitly asks for anything other than SSE-KMS.
        # The Null guard scopes this to requests that SET the header — a request
        # that omits it (relying on the bucket's default SSE-KMS) is still
        # encrypted, so denying it would be a footgun that 403s the eval-runner.
        Sid       = "DenyWrongEncryptionHeader"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.eval_reports.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
          Null = {
            "s3:x-amz-server-side-encryption" = "false"
          }
        }
      },
    ]
  })
}

################################################################################
# Publish the names the operator reads at startup. The operator resolves
# ArtifactsBucketName by sweeping /eks-agent-platform/<cluster>/, which its
# SSMRead statement already grants.
################################################################################

resource "aws_ssm_parameter" "model_artifacts_bucket_name" {
  name  = "${local.artifacts_ssm_prefix}/bucket_name"
  type  = "String"
  value = aws_s3_bucket.model_artifacts.id
  tags  = local.tags
}

resource "aws_ssm_parameter" "model_artifacts_bucket_arn" {
  name  = "${local.artifacts_ssm_prefix}/bucket_arn"
  type  = "String"
  value = aws_s3_bucket.model_artifacts.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "eval_reports_bucket_name" {
  name  = "${local.artifacts_ssm_prefix}/eval_reports_bucket_name"
  type  = "String"
  value = aws_s3_bucket.eval_reports.id
  tags  = local.tags
}

resource "aws_ssm_parameter" "eval_reports_bucket_arn" {
  name  = "${local.artifacts_ssm_prefix}/eval_reports_bucket_arn"
  type  = "String"
  value = aws_s3_bucket.eval_reports.arn
  tags  = local.tags
}
