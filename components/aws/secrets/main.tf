data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # var.secrets is sensitive, and for_each cannot iterate a sensitive value.
  # Secret NAMES are not secret — only the payloads are — so iterate unmarked
  # key sets and index back into var.secrets where a value is needed; the
  # secret_string stays sensitive end to end.
  secret_keys           = nonsensitive(toset(keys(var.secrets)))
  generated_secret_keys = toset([for k in local.secret_keys : k if nonsensitive(var.secrets[k].generate_random)])
  versioned_secret_keys = toset([for k in local.secret_keys : k if nonsensitive(var.secrets[k].secret_string != null || var.secrets[k].generate_random)])

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
  for_each = local.generated_secret_keys

  length  = nonsensitive(var.secrets[each.key].random_length)
  special = true
}

################################################################################
# Secrets Manager Secrets
################################################################################

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secret_keys

  name = "${var.environment}${var.secret_path_prefix}/${each.key}"
  # nonsensitive: metadata inherits the variable's mark, but description and
  # recovery window are not secret — unmark them so plans stay readable.
  description = nonsensitive(var.secrets[each.key].description != "" ? var.secrets[each.key].description : "Platform secret: ${each.key}")
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = nonsensitive(var.secrets[each.key].recovery_window_in_days)

  tags = merge(local.tags, { Name = each.key })
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each = local.versioned_secret_keys

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = var.secrets[each.key].generate_random ? random_password.this[each.key].result : var.secrets[each.key].secret_string
}

################################################################################
# External Secrets Operator identity is NOT created here.
#
# cluster-addons owns it (module.external_secrets_irsa in cluster-addons/irsa.tf),
# alongside every other addon's identity. This component used to ALSO create one —
# a second role, `<env>-eks-external-secrets-platform`, bound to the same
# ServiceAccount (external-secrets/external-secrets).
#
# A ServiceAccount can hold exactly ONE EKS Pod Identity association. secrets applies
# before cluster-addons, so it won the association and cluster-addons then failed:
#
#   Error: creating EKS Pod Identity Association
#     ResourceInUseException: The service account is already associated with a
#     different IAM role: arn:aws:iam::<acct>:role/dev-eks-external-secrets-platform
#
# Deterministic on every fresh install. Nothing consumed the role ARN this component
# exported, so the duplicate is removed rather than the addon's.
################################################################################


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

resource "aws_ssm_parameter" "secret_arns" {
  for_each = aws_secretsmanager_secret.this

  name  = "/platform/${var.environment}/secrets/${each.key}/arn"
  type  = "String"
  value = each.value.arn
  tags  = local.tags
}
