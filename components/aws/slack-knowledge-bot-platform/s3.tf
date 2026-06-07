/**
 * S3 audit-archive bucket. The audit-consumer pod writes
 * audit/<userId>/<date>/<queryHash>.json after the DDB write; the S3 copy
 * survives past the DDB TTL window for compliance.
 *
 * Lifecycle: Intelligent-Tiering after `audit_s3_intelligent_tiering_days`,
 * expiration after `audit_s3_lifecycle_days`.
 */

resource "aws_s3_bucket" "audit" {
  bucket = "${local.prefix}-audit"

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "intelligent-tiering-and-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = var.audit_s3_intelligent_tiering_days
      storage_class = "INTELLIGENT_TIERING"
    }

    expiration {
      days = var.audit_s3_lifecycle_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}
