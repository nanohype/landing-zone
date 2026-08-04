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

  # The four grants this component's keys hand out, declared once. Which KEY carries
  # which grant is the only thing var.separate_logs_key changes — the statements
  # themselves are identical in both modes, so the shared and separated postures cannot
  # drift apart in wording, only in placement.
  kms_root_statement = {
    Sid       = "EnableRootAccount"
    Effect    = "Allow"
    Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
    Action    = "kms:*"
    Resource  = "*"
  }

  # Scoped by SourceAccount so only Secrets Manager acting on behalf of this
  # account can use the key — parity with the AllowBedrock statement.
  kms_secretsmanager_statement = {
    Sid       = "AllowSecretsManagerService"
    Effect    = "Allow"
    Principal = { Service = "secretsmanager.amazonaws.com" }
    Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
    Resource  = "*"
    Condition = {
      StringEquals = {
        "aws:SourceAccount" = local.account_id
      }
    }
  }

  # CloudWatch Logs needs to use this key when any log group in the
  # account requests encryption with it. The EncryptionContext
  # condition scopes the grant to log-group ARNs in this account/region.
  kms_cloudwatch_logs_statement = {
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
  }

  # Bedrock needs to GenerateDataKey when writing invocation logs to
  # an S3 bucket encrypted with this key. Scoped by SourceAccount so
  # only Bedrock acting on behalf of this account can use the key.
  kms_bedrock_statement = {
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

  # The log-path grants MOVE when the logs key is separate. Leaving them on the secrets
  # key as well would let a log group encrypt under either key, which reads as a boundary
  # and enforces nothing.
  kms_log_path_statements = [local.kms_cloudwatch_logs_statement, local.kms_bedrock_statement]

  secrets_key_statements = concat(
    [local.kms_root_statement, local.kms_secretsmanager_statement],
    var.separate_logs_key ? [] : local.kms_log_path_statements,
  )

  logs_key_statements = concat([local.kms_root_statement], local.kms_log_path_statements)
}

################################################################################
# KMS Keys
#
# One key by default; two when var.separate_logs_key is set. See that variable for
# what the separation buys and what it costs. `logs_kms_key_arn` is published in both
# modes — equal to the secrets key when shared — so no consumer has to branch on the
# mode, and flipping it is an input change here rather than a change downstream.
################################################################################

resource "aws_kms_key" "secrets" {
  description             = "${var.environment} platform secrets encryption key"
  deletion_window_in_days = var.kms_deletion_window
  enable_key_rotation     = var.enable_key_rotation

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.secrets_key_statements
  })

  tags = merge(local.tags, { Name = "${var.environment}-platform-secrets" })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.environment}-platform-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_kms_key" "logs" {
  count = var.separate_logs_key ? 1 : 0

  description             = "${var.environment} platform logs encryption key"
  deletion_window_in_days = var.kms_deletion_window
  enable_key_rotation     = var.enable_key_rotation

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.logs_key_statements
  })

  tags = merge(local.tags, { Name = "${var.environment}-platform-logs" })
}

resource "aws_kms_alias" "logs" {
  count = var.separate_logs_key ? 1 : 0

  name          = "alias/${var.environment}-platform-logs"
  target_key_id = aws_kms_key.logs[0].key_id
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
# cluster-addons owns the external-secrets IRSA role (module.external_secrets_irsa in
# cluster-addons/pod-identity.tf), alongside every other addon's identity. A ServiceAccount holds
# exactly ONE EKS Pod Identity association, so the external-secrets/external-secrets SA's
# role lives in exactly one place — cluster-addons — and this component never binds it.
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
