################################################################################
# S3 Buckets (Deep Storage, Index Logs, MSQ Results)
################################################################################

module "deepstorage_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-deepstorage"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  attach_deny_insecure_transport_policy = true

  tags = local.tenant_tags
}

module "indexlogs_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-indexlogs"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "cleanup"
      enabled = true
      expiration = {
        days = var.tenant_config.index_logs_expiry
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tenant_tags
}

module "msq_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-msq"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "cleanup"
      enabled = true
      expiration = {
        days = var.tenant_config.msq_expiry
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tenant_tags
}
