data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  tags = merge(var.tags, {
    Component = "org-security"
    Team      = var.team
  })
}

################################################################################
# SNS Topic — Shared Security Alerts (SSE-KMS)
#
# EventBridge, GuardDuty, and Security Hub publish findings here; SSE-SNS makes
# SNS call kms:GenerateDataKey*/Decrypt as those service principals, so the key
# policy admits them (scoped to this account).
################################################################################

resource "aws_kms_key" "security_alerts" {
  description             = "org security alerts topic encryption key"
  deletion_window_in_days = 7
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
        Sid    = "AllowSecurityServicePublish"
        Effect = "Allow"
        Principal = {
          Service = [
            "events.amazonaws.com",
            "guardduty.amazonaws.com",
            "securityhub.amazonaws.com",
          ]
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
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

  tags = merge(local.tags, { Name = "org-security-alerts" })
}

resource "aws_kms_alias" "security_alerts" {
  name          = "alias/org-security-alerts"
  target_key_id = aws_kms_key.security_alerts.key_id
}

resource "aws_sns_topic" "security_alerts" {
  name              = "org-security-alerts"
  kms_master_key_id = aws_kms_key.security_alerts.arn
  tags              = merge(local.tags, { Name = "org-security-alerts" })
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
      },
      {
        Sid       = "AllowGuardDutyPublish"
        Effect    = "Allow"
        Principal = { Service = "guardduty.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
      },
      {
        Sid       = "AllowSecurityHubPublish"
        Effect    = "Allow"
        Principal = { Service = "securityhub.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_email_endpoints)

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "guardduty_detector_id" {
  count = var.enable_guardduty ? 1 : 0

  name  = "/platform/${var.environment}/security/guardduty-detector-id"
  type  = "String"
  value = aws_guardduty_detector.this[0].id
  tags  = local.tags
}

resource "aws_ssm_parameter" "securityhub_arn" {
  count = var.enable_security_hub ? 1 : 0

  name  = "/platform/${var.environment}/security/securityhub-arn"
  type  = "String"
  value = aws_securityhub_account.this[0].arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "sns_topic_arn" {
  name  = "/platform/${var.environment}/security/sns-topic-arn"
  type  = "String"
  value = aws_sns_topic.security_alerts.arn
  tags  = local.tags
}
