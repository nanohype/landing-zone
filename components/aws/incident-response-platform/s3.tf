/**
 * Long-term audit archive bucket for incident-response. The processor pod can write
 * postmortem PDFs, incident timeline snapshots, and any other artifact
 * worth keeping beyond the DDB audit table's TTL window.
 *
 * The incident-response IRSA role reaches this bucket through the app-access
 * policy (Platform.spec.identity.extraPolicyArns); this component owns the
 * bucket's resource policy, which seeds the in-transit-TLS deny baseline below.
 */

locals {
  # Account-qualified so the name is globally unique across accounts (S3's
  # namespace is global). The precondition asserts it against S3's 63-char limit.
  audit_bucket = "${local.prefix}-${local.account_id}-audit"
}

resource "aws_s3_bucket" "audit" {
  bucket = local.audit_bucket

  tags = local.tags

  lifecycle {
    precondition {
      condition     = length(local.audit_bucket) <= 63
      error_message = "bucket ${local.audit_bucket} exceeds S3's 63-character limit."
    }
  }
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

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.audit.arn,
        "${aws_s3_bucket.audit.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
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
