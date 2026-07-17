/**
 * S3 buckets for digest-pipeline.
 *
 * voice-baseline:
 *   Immutable corpus of voice-baseline examples. Pipeline reads from
 *   here to load few-shots for the Bedrock generator. Append-mostly;
 *   versioning enabled so older baselines are recoverable. Long
 *   noncurrent retention (default 365d).
 *
 * raw-aggregations:
 *   Per-run snapshots of the aggregator outputs before generation.
 *   Useful for debugging a bad newsletter draft. Time-windowed
 *   retention (default 90d) — debug value drops fast.
 */

locals {
  # Account-qualified so the names are globally unique across accounts (S3's
  # namespace is global). The preconditions assert them against S3's 63-char limit.
  voice_baseline_bucket   = "${local.prefix}-${local.account_id}-voice-baseline"
  raw_aggregations_bucket = "${local.prefix}-${local.account_id}-raw-aggregations"
}

resource "aws_s3_bucket" "voice_baseline" {
  bucket = local.voice_baseline_bucket

  tags = local.tags

  lifecycle {
    precondition {
      condition     = length(local.voice_baseline_bucket) <= 63
      error_message = "bucket ${local.voice_baseline_bucket} exceeds S3's 63-character limit."
    }
  }
}

resource "aws_s3_bucket_versioning" "voice_baseline" {
  bucket = aws_s3_bucket.voice_baseline.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "voice_baseline" {
  bucket = aws_s3_bucket.voice_baseline.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "voice_baseline" {
  bucket = aws_s3_bucket.voice_baseline.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "voice_baseline" {
  bucket = aws_s3_bucket.voice_baseline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.voice_baseline.arn,
        "${aws_s3_bucket.voice_baseline.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "voice_baseline" {
  bucket = aws_s3_bucket.voice_baseline.id

  rule {
    id     = "noncurrent-expire"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.voice_baseline_lifecycle_days
    }
  }
}

resource "aws_s3_bucket" "raw_aggregations" {
  bucket = local.raw_aggregations_bucket

  tags = local.tags

  lifecycle {
    precondition {
      condition     = length(local.raw_aggregations_bucket) <= 63
      error_message = "bucket ${local.raw_aggregations_bucket} exceeds S3's 63-character limit."
    }
  }
}

resource "aws_s3_bucket_versioning" "raw_aggregations" {
  bucket = aws_s3_bucket.raw_aggregations.id

  versioning_configuration {
    status = "Suspended" # debug snapshots; versions add no value
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_aggregations" {
  bucket = aws_s3_bucket.raw_aggregations.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "raw_aggregations" {
  bucket = aws_s3_bucket.raw_aggregations.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "raw_aggregations" {
  bucket = aws_s3_bucket.raw_aggregations.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.raw_aggregations.arn,
        "${aws_s3_bucket.raw_aggregations.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "raw_aggregations" {
  bucket = aws_s3_bucket.raw_aggregations.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.raw_aggregations_lifecycle_days
    }
  }
}
