################################################################################
# Agent-platform artifact buckets
#
# The operator's Platform controller calls ensureBucketPolicy() against a
# model-artifacts bucket on every Platform reconcile, and the eval-runner writes
# its reports to an eval-reports bucket. Neither bucket was created by any
# component: the operator therefore failed with `missing: [ArtifactsBucketName]`
# on startup, and once the name was supplied by hand it failed again on
#
#   ensureBucketPolicy failed: s3:GetBucketPolicy AccessDenied
#     User: .../development-platform-agent-platform-operator
#     Resource: arn:aws:s3:::<cluster>-<account>-<region>-model-artifacts
#
# leaving every Platform stuck in phase=Provisioning forever. The substrate the
# operator was written against simply did not exist.
#
# The buckets are cluster-scoped (one pair per cluster, shared across Platforms),
# so they belong here beside the operator's identity rather than in the per-tenant
# llm module — which is the only other place in the repo that names a model
# artifacts bucket, and which is never applied on the core path.
#
# Naming matches the account+region-qualified convention used elsewhere
# (<cluster>-<account>-<region>-*) because S3 bucket names are globally unique: two
# accounts standing up a cluster of the same name must not collide.
################################################################################

locals {
  # Region-qualified as well as account-qualified: S3's namespace is GLOBAL, so an
  # account deploying the same environment into two regions collides with itself
  # without it. See the note on bucket_prefix in cluster-addons/main.tf.
  #
  # This account+region-qualified bucket is the TIGHTEST cluster-scoped name in the org
  # and sets the clusterName length cap: it leaves 12 chars for the base token in us-west-2
  # (fewer in a longer region). The precondition below asserts it at plan time.
  model_artifacts_bucket = "${var.cluster_name}-${local.account_id}-${var.region}-model-artifacts"
  eval_reports_bucket    = "${var.cluster_name}-${local.account_id}-${var.region}-eval-reports"
  artifacts_ssm_prefix   = "/eks-agent-platform/${var.cluster_name}/model-artifacts"
}

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

# Versioning: model artifacts and eval reports are both evidence. An agent that
# overwrites a report, or a bad training run that clobbers a model, must not be
# able to destroy the prior object.
resource "aws_s3_bucket_versioning" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "eval_reports" {
  bucket = aws_s3_bucket.eval_reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "eval_reports" {
  bucket = aws_s3_bucket.eval_reports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# These hold model weights and evaluation evidence. Nothing about them is public,
# and the operator writes a bucket policy onto model-artifacts at runtime — block
# public access at the bucket so a mistaken policy cannot expose them.
resource "aws_s3_bucket_public_access_block" "model_artifacts" {
  bucket                  = aws_s3_bucket.model_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "eval_reports" {
  bucket                  = aws_s3_bucket.eval_reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################################################################################
# Publish the names the operator reads at startup.
#
# The operator resolves ArtifactsBucketName by sweeping
# /eks-agent-platform/<env>/, which is what its SSMRead statement already grants.
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
