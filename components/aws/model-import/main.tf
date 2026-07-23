################################################################################
# model-import — account-and-region-scoped substrate for Bedrock Custom Model
# Import: open-weight models served through the ordinary Bedrock runtime with no
# GPU nodes (see the open-weights plan). Two resources, both account+region
# scoped so they outlive any single cluster:
#
#   - the S3 staging bucket where open-weight files land in Hugging Face format
#     before an import job copies them into Bedrock's managed storage, and
#   - the IAM service role Bedrock assumes to read those files during a
#     CreateModelImportJob.
#
# Deliberately cluster-independent. An imported Bedrock model is an
# account+region resource that outlives any one cluster, so this substrate has
# no dependency on the cluster or on the secrets CMK (a per-cluster fan-out):
# tearing a cluster down must not orphan or destroy a model another cluster is
# serving, and an account-scoped bucket must not be encrypted under a
# cluster-scoped key. Importing a model is a deliberate, infrequent,
# account-level act run out of band — the operator does not own it — and a
# ModelGateway route then references the resulting imported-model ARN.
################################################################################

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Account+region-scoped names. The bucket carries the account id + region
  # because S3's namespace is global; the role carries the region because IAM is
  # account-global and two regions in one account must not mint the same role
  # name (the region-model collision lesson).
  staging_bucket   = "${local.account_id}-${var.region}-model-import"
  import_role_name = "model-import-${var.region}"

  ssm_prefix = "/eks-agent-platform/model-import"

  tags = merge(var.tags, {
    Component = "model-import"
    Team      = var.team
  })
}

################################################################################
# Staging bucket. SSE-S3, not a CMK: the files are open-weight models — public
# data — and the bucket must outlive any cluster, so it must not depend on the
# per-cluster secrets CMK. Public access blocked; versioned so a re-upload can't
# silently destroy a prior weight set; non-TLS access denied.
################################################################################

resource "aws_s3_bucket" "staging" {
  bucket = local.staging_bucket
  tags   = local.tags

  lifecycle {
    precondition {
      condition     = length(local.staging_bucket) <= 63
      error_message = "bucket ${local.staging_bucket} exceeds S3's 63-character limit."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "staging" {
  bucket                  = aws_s3_bucket.staging.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "staging" {
  bucket = aws_s3_bucket.staging.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.staging_noncurrent_expiration_days
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

resource "aws_s3_bucket_policy" "staging" {
  bucket     = aws_s3_bucket.staging.id
  depends_on = [aws_s3_bucket_public_access_block.staging]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.staging.arn,
        "${aws_s3_bucket.staging.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

################################################################################
# Import service role. Bedrock assumes this during a CreateModelImportJob to
# read the staged weights. Confused-deputy protection is aws:SourceAccount only.
# A model-import-job aws:SourceArn condition — which AWS's own doc example shows —
# is deliberately omitted: Bedrock validates this role during the create call,
# before the job (and its ARN) exists, so a job-scoped SourceArn can never be
# satisfied at validation time and the call fails with the misleading
# "The provided role ARN is invalid". SourceAccount pins the confused-deputy
# boundary to this account, which is the control that matters. The grant is
# read-only on this one bucket, pinned to same-account resources.
################################################################################

resource "aws_iam_role" "import" {
  name        = local.import_role_name
  description = "Bedrock Custom Model Import: assumed by Bedrock to read staged open-weight files during an import job"
  tags        = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "import_read_staging" {
  name = "read-staging-weights"
  role = aws_iam_role.import.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadStagingWeights"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
      ]
      Resource = [
        aws_s3_bucket.staging.arn,
        "${aws_s3_bucket.staging.arn}/*",
      ]
      Condition = {
        StringEquals = { "aws:ResourceAccount" = local.account_id }
      }
    }]
  })
}

################################################################################
# SSM discovery parameters — the out-of-band import procedure resolves the
# staging bucket and import role from here. Discovery metadata (names/ARNs),
# never secret values.
################################################################################

resource "aws_ssm_parameter" "staging_bucket" {
  name  = "${local.ssm_prefix}/staging_bucket_name"
  type  = "String"
  value = aws_s3_bucket.staging.bucket
  tags  = local.tags
}

resource "aws_ssm_parameter" "import_role_arn" {
  name  = "${local.ssm_prefix}/import_role_arn"
  type  = "String"
  value = aws_iam_role.import.arn
  tags  = local.tags
}
