resource "aws_kms_key" "documents" {
  description         = "KMS key for RAG documents - ${var.tenant_id}"
  enable_key_rotation = true
  tags                = local.tenant_tags
}

resource "aws_kms_alias" "documents" {
  name          = "alias/${var.environment}-rag-${var.tenant_id}-documents"
  target_key_id = aws_kms_key.documents.key_id
}

module "document_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-documents"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = { enabled = var.tenant_config.document_versioned }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.documents.arn
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id                                     = "incomplete-uploads"
      enabled                                = true
      abort_incomplete_multipart_upload_days = 7
    },
  ]

  attach_deny_insecure_transport_policy = true
  tags                                  = local.tenant_tags
}
