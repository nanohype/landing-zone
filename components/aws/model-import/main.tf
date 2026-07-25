################################################################################
# model-import — the IMPORT-TIME substrate for Bedrock Custom Model Import:
# open-weight models served through the ordinary Bedrock runtime with no GPU
# nodes (see the open-weights plan). Two resources:
#
#   - the S3 staging bucket where open-weight files land in Hugging Face format
#     before an import job copies them into Bedrock's managed storage, and
#   - the IAM service role Bedrock assumes to read those files during a
#     CreateModelImportJob.
#
# What this component does not own is the imported model. AWS manages and stores
# imported custom models itself, in AWS-managed storage scoped to the account and
# encrypted at rest by Bedrock. The S3 URI is read only while the import job runs,
# and the role's trust is pinned to model-import-job/* below, so it cannot be
# assumed at inference time at all.
#
# So destroying this component removes three things — the ability to run a NEW
# import, the staged source needed to re-import, and the SSM discovery
# parameters — and does not affect an already-imported model's availability to
# anything. That is why the substrate is safe to tear down alongside the
# environment that created it, and why the import runbook's teardown treats
# deleting the model and emptying this bucket as two independent acts.
#
# Two residual hazards, both real:
#
#   - an import job in flight when this is destroyed fails, because the role it
#     assumed and the source it reads both disappear under it, and
#   - force_destroy deletes staged weights permanently. They are re-uploadable
#     from the upstream model, which is what makes the guard acceptable, but
#     re-staging a large weight set costs time and transfer.
#
# Cluster-independent, and staying that way. Nothing here depends on the cluster
# or on the per-cluster secrets CMK (a per-cluster fan-out), because importing a
# model is a deliberate, infrequent, account-level act run out of band — the
# operator does not own it — and a ModelGateway route on any cluster in the
# account then references the resulting imported-model ARN.
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Environment+account+region-scoped names. The bucket carries the account id and
  # region because S3's namespace is global; both names carry the region because
  # IAM is account-global and two regions in one account must not mint the same
  # role name (the region-model collision lesson). All of that is unchanged.
  #
  # The environment segment is what keeps two environments in ONE account from
  # colliding, which is not hypothetical — this tree already places several
  # environments in a single account, and a caller that supplies one account id
  # for every environment makes it the normal case rather than the exception.
  # Without the segment a second environment's apply fails
  # BucketAlreadyOwnedByYou, and its teardown deletes the first environment's
  # substrate and discovery parameters. Note this is scoping by ENVIRONMENT, not
  # by cluster: the substrate stays shared by every cluster in an environment,
  # which is the property the header describes.
  #
  # It is also the shape nanohype/standards/resource-naming.json already requires
  # of an SSM prefix — /<repo>/<environment>/<component>/<key> — which this was
  # the only component in the org not to follow, and the environment-first bucket
  # form the cost component's CUR bucket already uses.
  staging_bucket   = "${var.environment}-${local.account_id}-${var.region}-model-import"
  import_role_name = "model-import-${var.environment}-${var.region}"

  ssm_prefix = "/eks-agent-platform/${var.environment}/model-import"

  tags = merge(var.tags, {
    Component = "model-import"
    Team      = var.team
  })
}

################################################################################
# Staging bucket. SSE-S3, not a CMK: the files are open-weight models — public
# data — and the bucket is shared by every cluster in the environment, so it must
# not depend on any one cluster's secrets CMK. Public access blocked; versioned so
# a re-upload can't silently destroy a prior weight set; non-TLS access denied.
################################################################################

resource "aws_s3_bucket" "staging" {
  bucket = local.staging_bucket
  tags   = local.tags

  # Versioned, so every superseded weight set blocks a delete as well. Unconditional in
  # development, elsewhere opt-in via var.force_destroy_buckets — matching agent-iam and
  # cluster-addons. Outside a permitted environment a destroy fails loudly rather than
  # silently discarding a weight set someone may be mid-import with.
  force_destroy = var.environment == "development" || var.force_destroy_buckets

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
# read the staged weights. Trust follows AWS's confused-deputy guidance: the
# Bedrock service principal, scoped by aws:SourceAccount and an aws:SourceArn
# pinned to model-import-job resources in this account+region (ArnEquals
# wildcard-matches the real job ARN). The grant is read-only on this one bucket,
# pinned to same-account resources.
#
# First-apply note: a freshly created role's trust can take several minutes to
# propagate before Bedrock's CreateModelImportJob validation accepts it — until
# then the call fails with the misleading "The provided role ARN is invalid".
# That is IAM eventual consistency, not a policy error; retry.
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
        ArnEquals    = { "aws:SourceArn" = "arn:${local.partition}:bedrock:${var.region}:${local.account_id}:model-import-job/*" }
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
