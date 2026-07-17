data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  tags = merge(var.tags, {
    Component = "service-quotas"
    Team      = var.team
  })
}

################################################################################
# Quota Lookup
################################################################################

data "aws_servicequotas_service_quota" "this" {
  for_each = var.monitored_quotas

  service_code = each.value.service_code
  quota_code   = each.value.quota_code
}

################################################################################
# SNS Topic for Alerts — SSE-KMS
#
# CloudWatch quota-utilization alarms publish here; SSE-SNS makes SNS call
# kms:GenerateDataKey*/Decrypt as the cloudwatch service principal, so the key
# policy admits it (scoped to this account).
################################################################################

resource "aws_kms_key" "quota_alerts" {
  description             = "${var.environment} service-quota alerts topic encryption key"
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
        Sid       = "AllowCloudWatchAlarmPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
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

  tags = local.tags
}

resource "aws_kms_alias" "quota_alerts" {
  name          = "alias/${var.environment}-service-quota-alerts"
  target_key_id = aws_kms_key.quota_alerts.key_id
}

resource "aws_sns_topic" "quota_alerts" {
  name              = "${var.environment}-service-quota-alerts"
  kms_master_key_id = aws_kms_key.quota_alerts.arn

  tags = local.tags
}

resource "aws_sns_topic_subscription" "quota_email" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.quota_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

################################################################################
# CloudWatch Alarms for Quota Utilization
################################################################################

resource "aws_cloudwatch_metric_alarm" "quota" {
  for_each = var.monitored_quotas

  alarm_name          = "${var.environment}-quota-${each.key}"
  alarm_description   = "Service quota alarm: ${each.value.description} exceeds ${var.quota_threshold_percent}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = data.aws_servicequotas_service_quota.this[each.key].value * var.quota_threshold_percent / 100

  metric_name = "ResourceCount"
  namespace   = "AWS/Usage"
  period      = 300
  statistic   = "Maximum"

  dimensions = {
    Type     = "Resource"
    Service  = each.value.service_code
    Resource = each.value.quota_code
    Class    = "None"
  }

  alarm_actions = [aws_sns_topic.quota_alerts.arn]

  tags = local.tags
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "quota_topic_arn" {
  name  = "/${var.environment}/service-quotas/alert-topic-arn"
  type  = "String"
  value = aws_sns_topic.quota_alerts.arn

  tags = local.tags
}
