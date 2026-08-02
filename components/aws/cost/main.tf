data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  tags = merge(var.tags, {
    Component = "cost"
    Team      = var.team
  })
}

################################################################################
# AWS Budget
################################################################################

resource "aws_budgets_budget" "monthly" {
  name         = "${var.environment}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Environment$${var.environment}"]
  }

  dynamic "notification" {
    for_each = var.budget_alert_thresholds
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value >= 100 ? "ACTUAL" : "FORECASTED"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}

################################################################################
# Cost Anomaly Detection
################################################################################

resource "aws_ce_anomaly_monitor" "this" {
  count = var.enable_anomaly_detection ? 1 : 0

  name              = "${var.environment}-cost-anomaly-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "this" {
  count = var.enable_anomaly_detection ? 1 : 0

  name = "${var.environment}-cost-anomaly-alerts"

  monitor_arn_list = [aws_ce_anomaly_monitor.this[0].arn]

  frequency = "DAILY"

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold)]
    }
  }

  dynamic "subscriber" {
    for_each = var.budget_alert_emails
    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }
}

################################################################################
# Cost Alerts SNS Topic — SSE-KMS
#
# AWS Cost Anomaly Detection publishes to this topic; SSE-SNS makes SNS call
# kms:GenerateDataKey*/Decrypt as the costalerts service principal, so the key
# policy admits it (scoped to this account).
################################################################################

resource "aws_kms_key" "cost_alerts" {
  description             = "${var.environment} cost alerts topic encryption key"
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
        Sid       = "AllowCostAnomalyPublish"
        Effect    = "Allow"
        Principal = { Service = "costalerts.amazonaws.com" }
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

resource "aws_kms_alias" "cost_alerts" {
  name          = "alias/${var.environment}-cost-alerts"
  target_key_id = aws_kms_key.cost_alerts.key_id
}

resource "aws_sns_topic" "cost_alerts" {
  name              = "${var.environment}-cost-alerts"
  kms_master_key_id = aws_kms_key.cost_alerts.arn

  tags = local.tags
}

resource "aws_sns_topic_subscription" "cost_alert_email" {
  for_each = toset(var.budget_alert_emails)

  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "budget_name" {
  name  = "/platform/${var.environment}/cost/budget-name"
  type  = "String"
  value = aws_budgets_budget.monthly.name
  tags  = local.tags
}

resource "aws_ssm_parameter" "budget_limit" {
  name  = "/platform/${var.environment}/cost/budget-limit"
  type  = "String"
  value = tostring(var.monthly_budget_limit)
  tags  = local.tags
}

resource "aws_ssm_parameter" "anomaly_monitor_arn" {
  count = var.enable_anomaly_detection ? 1 : 0

  name  = "/platform/${var.environment}/cost/anomaly-monitor-arn"
  type  = "String"
  value = aws_ce_anomaly_monitor.this[0].arn
  tags  = local.tags
}

################################################################################
# Per-Tenant Cost Anomaly Detection
################################################################################

resource "aws_ce_anomaly_monitor" "tenant" {
  for_each = var.enable_tenant_anomaly_detection ? var.tenant_names : toset([])

  name              = "${var.environment}-tenant-${each.key}-anomaly"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = merge(local.tags, {
    Tenant = each.key
  })
}

resource "aws_ce_anomaly_subscription" "tenant" {
  for_each = var.enable_tenant_anomaly_detection ? var.tenant_names : toset([])

  name = "${var.environment}-tenant-${each.key}-anomaly-sub"

  monitor_arn_list = [aws_ce_anomaly_monitor.tenant[each.key].arn]

  frequency = "DAILY"

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.tenant_anomaly_threshold)]
    }
  }

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.cost_alerts.arn
  }
}
