data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  tags = merge(var.tags, {
    Component = "secrets"
    Team      = var.team
  })
}

################################################################################
# KMS Key
################################################################################

resource "aws_kms_key" "secrets" {
  description             = "${var.environment} platform secrets encryption key"
  deletion_window_in_days = var.kms_deletion_window
  enable_key_rotation     = var.enable_key_rotation

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
        Sid       = "AllowSecretsManagerService"
        Effect    = "Allow"
        Principal = { Service = "secretsmanager.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
      },
      {
        # CloudWatch Logs needs to use this key when any log group in the
        # account requests encryption with it. The EncryptionContext
        # condition scopes the grant to log-group ARNs in this account/region.
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.region}:${local.account_id}:*"
          }
        }
      },
      {
        # Bedrock needs to GenerateDataKey when writing invocation logs to
        # an S3 bucket encrypted with this key. Scoped by SourceAccount so
        # only Bedrock acting on behalf of this account can use the key.
        Sid       = "AllowBedrock"
        Effect    = "Allow"
        Principal = { Service = "bedrock.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })

  tags = merge(local.tags, { Name = "${var.environment}-platform-secrets" })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.environment}-platform-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

################################################################################
# Random Passwords
################################################################################

resource "random_password" "this" {
  for_each = { for k, v in var.secrets : k => v if v.generate_random }

  length  = each.value.random_length
  special = true
}

################################################################################
# Secrets Manager Secrets
################################################################################

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secrets

  name        = "${var.environment}${var.secret_path_prefix}/${each.key}"
  description = each.value.description != "" ? each.value.description : "Platform secret: ${each.key}"
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = each.value.recovery_window_in_days

  tags = merge(local.tags, { Name = each.key })
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each = { for k, v in var.secrets : k => v if v.secret_string != null || v.generate_random }

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = each.value.generate_random ? random_password.this[each.key].result : each.value.secret_string
}

################################################################################
# IRSA — External Secrets Operator (Platform)
################################################################################

module "external_secrets_platform_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${var.environment}-eks-external-secrets-platform"
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds",
      ]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${var.environment}${var.secret_path_prefix}/*"
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      Resource = [aws_kms_key.secrets.arn]
    },
  ]

  tags = local.tags
}

################################################################################
# SSM Parameters — Bridge to GitOps
################################################################################

resource "aws_ssm_parameter" "kms_key_arn" {
  name  = "/platform/${var.environment}/secrets/kms-key-arn"
  type  = "String"
  value = aws_kms_key.secrets.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "kms_key_alias" {
  name  = "/platform/${var.environment}/secrets/kms-key-alias"
  type  = "String"
  value = aws_kms_alias.secrets.name
  tags  = local.tags
}

resource "aws_ssm_parameter" "irsa_role_arn" {
  name  = "/platform/${var.environment}/secrets/irsa-role-arn"
  type  = "String"
  value = module.external_secrets_platform_irsa.iam_role_arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "secret_arns" {
  for_each = aws_secretsmanager_secret.this

  name  = "/platform/${var.environment}/secrets/${each.key}/arn"
  type  = "String"
  value = each.value.arn
  tags  = local.tags
}
