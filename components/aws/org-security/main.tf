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
      {
        # EventBridge is a separate, unconditioned statement, matching the
        # observability and break-glass key policies. AWS does not document
        # whether EventBridge populates condition context on the KMS call it
        # makes to encrypt into an SSE-KMS topic, and an unpopulated key fails
        # closed — the finding is accepted and dropped with no error at the rule.
        # GuardDuty and Security Hub do populate it, which is why they keep their
        # guard above; this is a per-principal fact, not a house style.
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
        ]
        Resource = "*"
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

# Each publish grant is scoped to this account (aws:SourceAccount) — the same
# confused-deputy guard the alerts CMK policy carries. Without it, a security
# service principal acting for any account could inject findings into the alert
# channel operators trust.
resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # No Condition, deliberately. AWS documents that EventBridge does not
        # populate condition context on the SNS publish path — "You can't use
        # Condition blocks in Amazon SNS topic policies for EventBridge" — so an
        # aws:SourceAccount guard here never evaluates true and the statement
        # never allows. The rule reports success and the finding is dropped, with
        # the only trace a FailedInvocations counter on whichever rule targeted
        # the topic: a security alert path that looks installed and delivers
        # nothing.
        #
        # The GuardDuty and Security Hub statements below keep their guard
        # because those principals do populate it. This is a per-principal fact,
        # not a house style, and the topic ARN this statement names is what
        # bounds the grant in EventBridge's place.
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
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        Sid       = "AllowSecurityHubPublish"
        Effect    = "Allow"
        Principal = { Service = "securityhub.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
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
