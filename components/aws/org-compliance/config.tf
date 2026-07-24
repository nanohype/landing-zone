################################################################################
# AWS Config IAM Role
################################################################################

resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0

  name = "org-config-recorder"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "config" {
  count = var.enable_config ? 1 : 0

  role       = aws_iam_role.config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  count = var.enable_config ? 1 : 0

  name = "config-s3-delivery"
  role = aws_iam_role.config[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetBucketAcl"
        Resource = module.config_bucket[0].s3_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${module.config_bucket[0].s3_bucket_arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.compliance.arn
      },
    ]
  })
}

################################################################################
# Config S3 Bucket
################################################################################

module "config_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  count = var.enable_config ? 1 : 0

  bucket = "org-${local.account_id}-config-snapshots"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.compliance.arn
      }
      bucket_key_enabled = true
    }
  }

  attach_policy = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = "arn:aws:s3:::org-${local.account_id}-config-snapshots"
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "arn:aws:s3:::org-${local.account_id}-config-snapshots/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
    ]
  })

  tags = merge(local.tags, { Name = "org-config-snapshots" })
}

################################################################################
# Configuration Recorder
################################################################################

resource "aws_config_configuration_recorder" "this" {
  count = var.enable_config ? 1 : 0

  name     = "org-config-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }

  recording_mode {
    recording_frequency = "CONTINUOUS"
  }
}

resource "aws_config_delivery_channel" "this" {
  count = var.enable_config ? 1 : 0

  name           = "org-config-delivery"
  s3_bucket_name = module.config_bucket[0].s3_bucket_id
  s3_key_prefix  = "config"

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  count = var.enable_config ? 1 : 0

  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

################################################################################
# Config Rules
################################################################################

resource "aws_config_config_rule" "this" {
  for_each = var.enable_config ? var.config_rules : {}

  name = each.key

  source {
    owner             = "AWS"
    source_identifier = each.value.source_identifier
  }

  input_parameters = length(each.value.input_parameters) > 0 ? jsonencode(each.value.input_parameters) : null

  depends_on = [aws_config_configuration_recorder.this]

  tags = local.tags
}

################################################################################
# Organization Managed Rules
################################################################################

# Deployed from this account across every member account, so the check evaluates resources
# where they live — a workload account's Aurora / DynamoDB / S3 / EFS, not just this account's.
# Backup coverage is the motivating case: BACKUP_RESOURCES_PROTECTED_BY_BACKUP_PLAN flags a
# backup-eligible resource protected by no plan (the silently-unprotected gap), the detective
# half of central-backup's coverage enforcement.
resource "aws_config_organization_managed_rule" "this" {
  for_each = var.enable_config ? var.organization_managed_rules : {}

  name            = each.key
  rule_identifier = each.value.rule_identifier
  description     = each.value.description != "" ? each.value.description : null

  input_parameters     = length(each.value.input_parameters) > 0 ? jsonencode(each.value.input_parameters) : null
  resource_types_scope = length(each.value.resource_types_scope) > 0 ? each.value.resource_types_scope : null
  excluded_accounts    = length(each.value.excluded_accounts) > 0 ? each.value.excluded_accounts : null

  depends_on = [aws_config_configuration_recorder.this]
}

################################################################################
# Conformance Packs
################################################################################

resource "aws_config_conformance_pack" "this" {
  for_each = var.enable_config ? toset(var.conformance_packs) : toset([])

  name            = each.value
  template_s3_uri = "s3://aws-configconformancepacktemplates-${local.region}/${each.value}.yaml"

  depends_on = [aws_config_configuration_recorder.this]
}

################################################################################
# Organization Aggregator
################################################################################

resource "aws_iam_role" "config_aggregator" {
  count = var.enable_config && var.enable_config_aggregator ? 1 : 0

  name = "org-config-aggregator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "config_aggregator" {
  count = var.enable_config && var.enable_config_aggregator ? 1 : 0

  role       = aws_iam_role.config_aggregator[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
}

resource "aws_config_configuration_aggregator" "org" {
  count = var.enable_config && var.enable_config_aggregator ? 1 : 0

  name = "org-config-aggregator"

  organization_aggregation_source {
    all_regions = true
    role_arn    = aws_iam_role.config_aggregator[0].arn
  }

  tags = local.tags
}
