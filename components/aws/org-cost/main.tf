data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  tags = merge(var.tags, {
    Component = "org-cost"
    Team      = var.team
  })
}

################################################################################
# Cost Categories
################################################################################

resource "aws_ce_cost_category" "this" {
  for_each = var.cost_categories

  name          = each.key
  rule_version  = each.value.rule_version
  default_value = each.value.default_value

  dynamic "rule" {
    for_each = each.value.rules
    content {
      value = rule.value.value
      rule {
        tags {
          key           = rule.value.rule.tags.key
          values        = rule.value.rule.tags.values
          match_options = ["EQUALS"]
        }
      }
    }
  }

  tags = local.tags
}

################################################################################
# Org-Wide Monthly Budget
################################################################################

resource "aws_budgets_budget" "org_monthly" {
  name         = "org-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.org_budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

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

resource "aws_ce_anomaly_monitor" "service" {
  count = var.enable_anomaly_detection ? 1 : 0

  name              = "org-anomaly-monitor-by-service"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = local.tags
}

resource "aws_ce_anomaly_monitor" "linked_account" {
  count = var.enable_anomaly_detection ? 1 : 0

  name         = "org-anomaly-monitor-by-account"
  monitor_type = "CUSTOM"

  monitor_specification = jsonencode({
    And = null
    Or  = null
    Not = null
    Dimensions = {
      Key          = "LINKED_ACCOUNT"
      MatchOptions = null
      Values       = null
    }
    Tags           = null
    CostCategories = null
  })

  tags = local.tags
}

resource "aws_ce_anomaly_subscription" "this" {
  count = var.enable_anomaly_detection ? 1 : 0

  name = "org-cost-anomaly-alerts"

  monitor_arn_list = [
    aws_ce_anomaly_monitor.service[0].arn,
    aws_ce_anomaly_monitor.linked_account[0].arn,
  ]

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
# Compute Optimizer
################################################################################

resource "aws_computeoptimizer_enrollment_status" "this" {
  count = var.enable_compute_optimizer ? 1 : 0

  status                  = "Active"
  include_member_accounts = true
}

################################################################################
# Savings Plans Utilization Alarm
################################################################################

resource "aws_cloudwatch_metric_alarm" "savings_plans_utilization" {
  count = var.enable_savings_plans_alarm ? 1 : 0

  alarm_name        = "org-savings-plans-utilization"
  alarm_description = "Alert when Savings Plans utilization drops below 80%"

  namespace           = "AWS/SavingsPlans"
  metric_name         = "UtilizationPercentage"
  statistic           = "Average"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 80
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  tags = local.tags
}

################################################################################
# CUR 2.0 Export
################################################################################

module "cur_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  count = var.enable_cur_export ? 1 : 0

  bucket = "org-${local.account_id}-cur-export"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "transition-to-ia"
      enabled = true
      transition = [
        {
          days          = 90
          storage_class = "STANDARD_IA"
        }
      ]
    }
  ]

  attach_policy = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowBCMExportDelivery"
        Effect    = "Allow"
        Principal = { Service = "bcm-data-exports.amazonaws.com" }
        Action    = ["s3:PutObject", "s3:GetBucketPolicy"]
        Resource = [
          "arn:aws:s3:::org-${local.account_id}-cur-export",
          "arn:aws:s3:::org-${local.account_id}-cur-export/*",
        ]
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.tags, { Name = "org-cur-export" })
}

resource "aws_bcmdataexports_export" "cur" {
  count = var.enable_cur_export ? 1 : 0

  export {
    name = "org-cur-2-export"

    data_query {
      query_statement = "SELECT * FROM COST_AND_USAGE_REPORT"
      table_configurations = {
        COST_AND_USAGE_REPORT = {
          TIME_GRANULARITY                   = "HOURLY"
          INCLUDE_RESOURCES                  = "TRUE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA = "TRUE"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = module.cur_bucket[0].s3_bucket_id
        s3_prefix = "cur"
        s3_region = local.region

        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "budget_name" {
  name  = "/platform/${var.environment}/cost/budget-name"
  type  = "String"
  value = aws_budgets_budget.org_monthly.name
  tags  = local.tags
}

resource "aws_ssm_parameter" "budget_limit" {
  name  = "/platform/${var.environment}/cost/budget-limit"
  type  = "String"
  value = tostring(var.org_budget_limit)
  tags  = local.tags
}

resource "aws_ssm_parameter" "anomaly_monitor_service_arn" {
  count = var.enable_anomaly_detection ? 1 : 0

  name  = "/platform/${var.environment}/cost/anomaly-monitor-service-arn"
  type  = "String"
  value = aws_ce_anomaly_monitor.service[0].arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "cur_export_bucket" {
  count = var.enable_cur_export ? 1 : 0

  name  = "/platform/${var.environment}/cost/cur-export-bucket"
  type  = "String"
  value = module.cur_bucket[0].s3_bucket_id
  tags  = local.tags
}

resource "aws_ssm_parameter" "cost_category_arns" {
  for_each = aws_ce_cost_category.this

  name  = "/platform/${var.environment}/cost/categories/${each.key}/arn"
  type  = "String"
  value = each.value.arn
  tags  = local.tags
}
