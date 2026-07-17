################################################################################
# Data Lake — S3 Buckets + KMS
################################################################################

locals {
  prefix    = "${var.environment}-pipeline-${var.tenant_id}"
  namespace = "pipeline-${var.tenant_id}"
  # Account-qualified so S3 bucket names are globally unique (S3's namespace is
  # global; two accounts vending the same env+tenant must not collide). The
  # component's `tenants` variable validation asserts the composed length fits 63.
  bucket_prefix = "${local.prefix}-${var.account_id}"
  tenant_tags   = merge(var.tags, { Tenant = var.tenant_id })
}

resource "aws_kms_key" "datalake" {
  description         = "KMS key for pipeline data lake - ${var.tenant_id}"
  enable_key_rotation = true
  tags                = local.tenant_tags
}

resource "aws_kms_alias" "datalake" {
  name          = "alias/pipeline/${var.environment}/${var.tenant_id}/datalake"
  target_key_id = aws_kms_key.datalake.key_id
}

module "raw_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-raw"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.datalake.arn
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id         = "ia-transition"
      enabled    = true
      transition = [{ days = var.tenant_config.raw_lifecycle_ia_days, storage_class = "STANDARD_IA" }]
    },
    {
      id         = "expiry"
      enabled    = true
      expiration = { days = var.tenant_config.raw_lifecycle_expiry_days }
    },
  ]

  attach_deny_insecure_transport_policy = true
  tags                                  = local.tenant_tags
}

module "staging_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-staging"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.datalake.arn
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id         = "expiry"
      enabled    = true
      expiration = { days = var.tenant_config.staging_lifecycle_expiry_days }
    },
  ]

  attach_deny_insecure_transport_policy = true
  tags                                  = local.tenant_tags
}

module "curated_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-curated"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.datalake.arn
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id                            = "version-expiry"
      enabled                       = true
      noncurrent_version_expiration = { days = var.tenant_config.curated_version_expiry_days }
    },
  ]

  attach_deny_insecure_transport_policy = true
  tags                                  = local.tenant_tags
}
