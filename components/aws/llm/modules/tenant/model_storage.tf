locals {
  prefix    = "${var.environment}-llm-${var.tenant_id}"
  namespace = "llm-${var.tenant_id}"
  # Account-qualified so S3 bucket names are globally unique (S3's namespace is
  # global). The component's `tenants` variable validation asserts the composed
  # length fits 63.
  bucket_prefix = "${local.prefix}-${var.account_id}"
  tenant_tags   = merge(var.tags, { Tenant = var.tenant_id })
}

resource "aws_kms_key" "models" {
  description         = "KMS key for LLM model storage - ${var.tenant_id}"
  enable_key_rotation = true
  tags                = local.tenant_tags
}

resource "aws_kms_alias" "models" {
  name          = "alias/llm/${var.environment}/${var.tenant_id}/models"
  target_key_id = aws_kms_key.models.key_id
}

module "model_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-models"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.models.arn
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id                            = "old-versions"
      enabled                       = true
      noncurrent_version_expiration = { days = var.tenant_config.model_version_expiry_days }
    },
    {
      id                                     = "incomplete-uploads"
      enabled                                = true
      abort_incomplete_multipart_upload_days = var.tenant_config.incomplete_upload_expiry_days
    },
  ]

  attach_deny_insecure_transport_policy = true
  tags                                  = local.tenant_tags
}
