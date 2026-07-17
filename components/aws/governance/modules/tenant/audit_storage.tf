locals {
  prefix    = "${var.environment}-governance-${var.tenant_id}"
  namespace = "governance-${var.tenant_id}"
  # Account-qualified so S3 bucket names are globally unique (S3's namespace is
  # global). The component's `tenants` variable validation asserts the composed
  # length fits 63.
  bucket_prefix = "${local.prefix}-${var.account_id}"
  tenant_tags   = merge(var.tags, { Tenant = var.tenant_id })
}

resource "aws_kms_key" "audit" {
  description             = "KMS key for governance audit - ${var.tenant_id}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tenant_tags
}

resource "aws_kms_alias" "audit" {
  name          = "alias/governance/${var.environment}/${var.tenant_id}/audit"
  target_key_id = aws_kms_key.audit.key_id
}

module "audit_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-audit"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.audit.arn
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id      = "ia-transition"
      enabled = true
      transition = [
        { days = var.tenant_config.lifecycle_ia_days, storage_class = "STANDARD_IA" },
        { days = var.tenant_config.lifecycle_glacier_days, storage_class = "GLACIER" },
      ]
    },
  ]

  attach_deny_insecure_transport_policy = true
  tags                                  = local.tenant_tags
}
