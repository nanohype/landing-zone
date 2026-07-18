################################################################################
# CloudTrail S3 Bucket
################################################################################

module "cloudtrail_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  count = var.enable_cloudtrail ? 1 : 0

  bucket = "org-${local.account_id}-cloudtrail-logs"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.compliance.arn
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id      = "cloudtrail-lifecycle"
      enabled = true
      transition = [
        {
          days          = 90
          storage_class = "STANDARD_IA"
        },
        {
          days          = 365
          storage_class = "GLACIER"
        },
      ]
      expiration = {
        days = var.cloudtrail_s3_retention
      }
    }
  ]

  attach_policy = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = "arn:aws:s3:::org-${local.account_id}-cloudtrail-logs"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "arn:aws:s3:::org-${local.account_id}-cloudtrail-logs/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = local.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.tags, { Name = "org-cloudtrail-logs" })
}

################################################################################
# CloudWatch Log Group (for Log Insights)
################################################################################

resource "aws_cloudwatch_log_group" "cloudtrail" {
  count = var.enable_cloudtrail && var.enable_log_insights ? 1 : 0

  name              = "/aws/cloudtrail/org"
  retention_in_days = 90

  tags = local.tags
}

resource "aws_iam_role" "cloudtrail_cloudwatch" {
  count = var.enable_cloudtrail && var.enable_log_insights ? 1 : 0

  name = "org-cloudtrail-cloudwatch-delivery"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  count = var.enable_cloudtrail && var.enable_log_insights ? 1 : 0

  name = "cloudwatch-logs-delivery"
  role = aws_iam_role.cloudtrail_cloudwatch[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
      }
    ]
  })
}

################################################################################
# CloudTrail
################################################################################

resource "aws_cloudtrail" "org" {
  #checkov:skip=CKV_AWS_252:no SNS topic by design — the trail archives to S3 and is queried via Athena; there is no push consumer to notify.
  count = var.enable_cloudtrail ? 1 : 0

  name                          = "org-trail"
  s3_bucket_name                = module.cloudtrail_bucket[0].s3_bucket_id
  is_organization_trail         = var.enable_org_trail
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.compliance.arn

  cloud_watch_logs_group_arn = var.enable_log_insights ? "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*" : null
  cloud_watch_logs_role_arn  = var.enable_log_insights ? aws_iam_role.cloudtrail_cloudwatch[0].arn : null

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3"]
    }
  }

  insight_selector {
    insight_type = "ApiCallRateInsight"
  }

  insight_selector {
    insight_type = "ApiErrorRateInsight"
  }

  tags = merge(local.tags, { Name = "org-trail" })
}
