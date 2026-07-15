/**
 * Long-term audit archive bucket for incident-response. The processor pod can write
 * postmortem PDFs, incident timeline snapshots, and any other artifact
 * worth keeping beyond the DDB audit table's TTL window.
 *
 * The chart's Platform CR also references this bucket as
 * spec.storage.bucket — the eks-agent-platform operator applies the
 * bucket policy that scopes access to the incident-response IRSA role.
 */

resource "aws_s3_bucket" "audit" {
  bucket = "${local.prefix}-audit"

  tags = local.tags
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
    id     = "intelligent-tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "INTELLIGENT_TIERING"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}
