################################################################################
# objectStore -> S3
################################################################################

locals {
  # Account-qualified so the name is globally unique across accounts (S3's
  # namespace is global). The component-level tenants validation asserts the
  # composed length fits S3's 63-char limit.
  object_store_buckets = {
    for name, d in local.object_stores : name => "${local.prefix}-${name}-${var.account_id}"
  }
}

resource "aws_s3_bucket" "object_store" {
  #checkov:skip=CKV_AWS_21:versioning is tenant-configurable and defaults Enabled (see aws_s3_bucket_versioning.object_store); a datastore opting a regenerable-data bucket to Suspended is a deliberate per-datastore posture choice, and checkov cannot resolve the per-tenant value
  for_each = local.object_stores

  bucket = local.object_store_buckets[each.key]

  tags = local.data_tags
}

resource "aws_s3_bucket_versioning" "object_store" {
  for_each = local.object_stores

  bucket = aws_s3_bucket.object_store[each.key].id

  versioning_configuration {
    status = each.value.object_store.versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "object_store" {
  for_each = local.object_stores

  bucket = aws_s3_bucket.object_store[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "object_store" {
  for_each = local.object_stores

  bucket = aws_s3_bucket.object_store[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "object_store" {
  for_each = local.object_stores

  bucket = aws_s3_bucket.object_store[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.object_store[each.key].arn,
        "${aws_s3_bucket.object_store[each.key].arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "object_store" {
  # Only when the datastore declares an expiry — a 0 default keeps objects
  # indefinitely and creates no lifecycle configuration.
  for_each = { for name, d in local.object_stores : name => d if d.object_store.lifecycle_expire_days > 0 }

  bucket = aws_s3_bucket.object_store[each.key].id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = each.value.object_store.lifecycle_expire_days
    }
  }
}
