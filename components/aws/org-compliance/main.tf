data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  tags = merge(var.tags, {
    Component = "org-compliance"
    Team      = var.team
  })
}

################################################################################
# Shared KMS Key — CloudTrail + Config
################################################################################

resource "aws_kms_key" "compliance" {
  description             = "Org compliance encryption key (CloudTrail + Config)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudTrailEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        # Scoped by SourceAccount so only CloudTrail acting on behalf of this
        # account can decrypt with the key — parity with AllowCloudTrailEncrypt.
        Sid       = "AllowCloudTrailDecrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        # Same SourceAccount scoping for AWS Config's use of the shared key.
        Sid       = "AllowConfigEncrypt"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.tags, { Name = "org-compliance" })
}

resource "aws_kms_alias" "compliance" {
  name          = "alias/org-compliance"
  target_key_id = aws_kms_key.compliance.key_id
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "kms_key_arn" {
  name  = "/platform/${var.environment}/compliance/kms-key-arn"
  type  = "String"
  value = aws_kms_key.compliance.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "cloudtrail_arn" {
  count = var.enable_cloudtrail ? 1 : 0

  name  = "/platform/${var.environment}/compliance/cloudtrail-arn"
  type  = "String"
  value = aws_cloudtrail.org[0].arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "cloudtrail_bucket" {
  count = var.enable_cloudtrail ? 1 : 0

  name  = "/platform/${var.environment}/compliance/cloudtrail-bucket"
  type  = "String"
  value = module.cloudtrail_bucket[0].s3_bucket_id
  tags  = local.tags
}

resource "aws_ssm_parameter" "config_recorder_id" {
  count = var.enable_config ? 1 : 0

  name  = "/platform/${var.environment}/compliance/config-recorder-id"
  type  = "String"
  value = aws_config_configuration_recorder.this[0].id
  tags  = local.tags
}
