################################################################################
# Addon S3 Buckets
################################################################################

# Velero backup storage (conditional)
module "velero_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"
  count   = var.velero_enabled ? 1 : 0

  bucket = "${local.bucket_prefix}-velero"

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
        days = var.environment == "production" ? 90 : 30
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tags
}

# Loki log storage
module "loki_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-loki"

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
        days = var.environment == "production" ? 90 : (var.environment == "staging" ? 30 : 14)
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tags
}

# Tempo trace storage
module "tempo_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.bucket_prefix}-tempo"

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
        days = var.environment == "production" ? 30 : 7
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tags
}

# Argo Workflows artifact storage (conditional)
module "argo_workflows_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"
  count   = var.argo_workflows_enabled ? 1 : 0

  bucket = "${local.bucket_prefix}-argo-workflows"

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
        days = 30
      }
    },
  ]

  attach_deny_insecure_transport_policy = true

  tags = local.tags
}

################################################################################
# Bucket-name guard
#
# S3 rejects any name over 63 characters, and it rejects it at APPLY — halfway
# through creating the addons, with some buckets made and some not. Catch it at PLAN.
#
# The four buckets above are terraform-aws-modules/s3-bucket module blocks, and a
# module block cannot carry a lifecycle precondition. A `check` block only emits a
# warning, which is not a gate. So the assertion lives on a terraform_data resource,
# which creates nothing and fails the plan.
#
# Worst case today is 62 chars (production-platform-<12-digit-account>-ap-southeast-4-
# argo-workflows). The headroom is one character — a longer cluster_name is the
# thing that will break this, and this is what will tell you so.
################################################################################

resource "terraform_data" "bucket_name_guard" {
  lifecycle {
    precondition {
      condition = alltrue([
        for name in ["velero", "loki", "tempo", "argo-workflows"] :
        length("${local.bucket_prefix}-${name}") <= 63
      ])
      error_message = format(
        "S3 bucket names are limited to 63 characters and the prefix %q (%d chars) leaves too little room: %s. Shorten var.cluster_name.",
        local.bucket_prefix,
        length(local.bucket_prefix),
        join(", ", [
          for name in ["velero", "loki", "tempo", "argo-workflows"] :
          format("%s-%s (%d)", local.bucket_prefix, name, length("${local.bucket_prefix}-${name}"))
          if length("${local.bucket_prefix}-${name}") > 63
        ])
      )
    }
  }
}
