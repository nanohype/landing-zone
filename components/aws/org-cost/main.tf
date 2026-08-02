data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  tags = merge(var.tags, {
    Component = "org-cost"
    Team      = var.team
  })

  # The export's identity, defined once. Consumers locate the data at
  # s3://<bucket>/<prefix>/<export name>/, so all three are contract, and a contract
  # published from a different expression than the one the resource used is a contract
  # that can drift silently — the reader finds an empty prefix and reports no spend
  # rather than an error.
  cur_export_name   = "org-cur-2-export"
  cur_export_prefix = "cur"

  # AWS's documented delivery policy, exactly. Data Exports writes objects and nothing
  # else, so the grant is s3:PutObject on the key space only — not the bucket ARN, and
  # not s3:GetBucketPolicy, which the service does not need.
  #
  # The aws:SourceArn condition is the confused-deputy guard. SourceAccount alone only
  # says "some service in this account asked", which every export in the account
  # satisfies equally — including exports owned by a different estate sharing the
  # account. The ARN is pinned to us-east-1 no matter where this component is applied,
  # because bcm-data-exports is a global endpoint whose ARNs always carry that region.
  #
  # A local rather than an inline argument to the module call so the suite can read it.
  # Inline, this policy is an untestable expression buried in a module input, and the
  # first draft of it lost the SourceArn condition with every assertion still green.
  cur_bucket_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAWSDataExportsToWriteToS3"
        Effect    = "Allow"
        Principal = { Service = "bcm-data-exports.amazonaws.com" }
        Action    = ["s3:PutObject"]
        Resource  = ["arn:${data.aws_partition.current.partition}:s3:::org-${local.account_id}-cur-export/*"]
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:bcm-data-exports:us-east-1:${local.account_id}:export/*"
          }
        }
      },
    ]
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
  policy        = local.cur_bucket_policy

  tags = merge(local.tags, { Name = "org-cur-export" })
}

resource "aws_bcmdataexports_export" "cur" {
  count = var.enable_cur_export ? 1 : 0

  export {
    name = local.cur_export_name

    data_query {
      query_statement = "SELECT * FROM COST_AND_USAGE_REPORT"
      # Every key, not the interesting ones. AWS: "If a value is set for
      # table_configurations, all configuration values must be set. For the Cost and
      # Usage Report, BILLING_VIEW_ARN must also be set, in addition to the documented
      # settings." A partial map is rejected, so the completeness is load-bearing rather
      # than stylistic.
      #
      # And it is one-shot: "Table configurations can't be changed after an export is
      # created." Getting this wrong is not a diff to fix later — the export has to be
      # destroyed and recreated, and AWS is explicit that existing exports do not
      # retroactively gain identity data. That is why the suite asserts each key.
      table_configurations = {
        COST_AND_USAGE_REPORT = {
          BILLING_VIEW_ARN                      = "arn:${data.aws_partition.current.partition}:billing::${local.account_id}:billingview/primary"
          TIME_GRANULARITY                      = "HOURLY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "TRUE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"

          # Caller identity. This is what puts `line_item_iam_principal` in the export
          # and surfaces IAM principal tags as `iamPrincipal/<key>` columns, and it is
          # the only way to attribute Amazon Bedrock spend to anything.
          #
          # A model invocation is not a taggable resource, so no `resourceTags/` column
          # is ever populated on a Bedrock line item — an attribution query filtering on
          # a resource tag returns nothing, successfully, forever. AWS attributes that
          # spend by the identity that made the call instead, and states plainly that
          # "IAM principal identity and tag data requires CUR 2.0 (AWS Data Exports). If
          # you are using the legacy CUR format, IAM principal fields will not be
          # available."
          #
          # Costs rows: the export multiplies by the number of calling identities per
          # model. That is the price of the only attribution that works.
          INCLUDE_IAM_PRINCIPAL_DATA = "TRUE"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = module.cur_bucket[0].s3_bucket_id
        s3_prefix = local.cur_export_prefix
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

# The rest of the location. A consumer building an Athena table over this export needs
# all three parts — the data sits at s3://<bucket>/<prefix>/<export name>/ — and
# publishing only the bucket leaves the other two to be guessed. A guessed prefix does
# not fail: the crawler finds no objects, registers a table with no partitions, and
# every query against it returns zero rows and exit status success.
resource "aws_ssm_parameter" "cur_export_prefix" {
  count = var.enable_cur_export ? 1 : 0

  name  = "/platform/${var.environment}/cost/cur-export-prefix"
  type  = "String"
  value = local.cur_export_prefix
  tags  = local.tags
}

resource "aws_ssm_parameter" "cur_export_name" {
  count = var.enable_cur_export ? 1 : 0

  name  = "/platform/${var.environment}/cost/cur-export-name"
  type  = "String"
  value = local.cur_export_name
  tags  = local.tags
}

resource "aws_ssm_parameter" "cost_category_arns" {
  for_each = aws_ce_cost_category.this

  name  = "/platform/${var.environment}/cost/categories/${each.key}/arn"
  type  = "String"
  value = each.value.arn
  tags  = local.tags
}
