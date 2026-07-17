################################################################################
# KMS Key + S3 Buckets (Datasets, Artifacts)
################################################################################

locals {
  prefix    = "${var.environment}-mlops-${var.tenant_id}"
  namespace = "mlops-${var.tenant_id}"
  # Account-qualified so S3 bucket names are globally unique (S3's namespace is
  # global). The component's `tenants` variable validation asserts the composed
  # length fits 63.
  bucket_prefix = "${local.prefix}-${var.account_id}"
  tenant_tags   = merge(var.tags, { Tenant = var.tenant_id })
}

resource "aws_kms_key" "this" {
  description         = "KMS key for MLOps - ${var.tenant_id}"
  enable_key_rotation = true
  tags                = local.tenant_tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/mlops/${var.environment}/${var.tenant_id}"
  target_key_id = aws_kms_key.this.key_id
}

module "datasets_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-datasets"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.this.arn
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id         = "ia-transition"
      enabled    = true
      transition = [{ days = var.tenant_config.datasets_lifecycle_ia_days, storage_class = "STANDARD_IA" }]
    },
    {
      id                            = "version-expiry"
      enabled                       = true
      noncurrent_version_expiration = { days = var.tenant_config.datasets_version_expiry_days }
    },
  ]

  attach_deny_insecure_transport_policy = true
  tags                                  = local.tenant_tags
}

module "artifacts_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-artifacts"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.this.arn
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id         = "ia-transition"
      enabled    = true
      transition = [{ days = var.tenant_config.artifacts_lifecycle_ia_days, storage_class = "STANDARD_IA" }]
    },
    {
      id                            = "version-expiry"
      enabled                       = true
      noncurrent_version_expiration = { days = var.tenant_config.artifacts_version_expiry_days }
    },
  ]

  attach_deny_insecure_transport_policy = true
  tags                                  = local.tenant_tags
}
