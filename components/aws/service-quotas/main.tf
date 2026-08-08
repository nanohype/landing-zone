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

locals {
  # `usage_metric` is a list, and it is EMPTY for any quota AWS publishes no
  # CloudWatch usage metric for — which is most of them. A quota with no usage
  # metric cannot be alarmed at any dimension set, so the precondition on the
  # SNS topic below refuses the plan rather than letting this component build an
  # alarm that is dead the moment it is created.
  unmonitorable_quotas = [
    for k, _ in var.monitored_quotas : k
    if length(data.aws_servicequotas_service_quota.this[k].usage_metric) == 0
  ]

  # Restricted to the monitorable keys so that indexing [0] below cannot fail.
  # Built over every key instead, an unmonitorable quota aborts the plan with a
  # bare "Invalid index" from inside a local, and the precondition that explains
  # the problem never gets to run. The precondition is still what stops the
  # apply — this only decides which error the operator reads.
  monitorable_quotas = {
    for k, v in var.monitored_quotas : k => v
    if length(data.aws_servicequotas_service_quota.this[k].usage_metric) > 0
  }

  quota_usage = {
    for k, _ in local.monitorable_quotas :
    k => data.aws_servicequotas_service_quota.this[k].usage_metric[0]
  }

  # A dimensionless metric does NOT come back as an empty metric_dimensions
  # list. Lambda's ConcurrentExecutions returns a single element whose four
  # fields are all null, so testing the list length passes and yields a map of
  # four null dimensions — which CloudWatch rejects. Filtering on the values is
  # what distinguishes "no dimensions" from "dimensions I failed to read".
  quota_dimensions = {
    for k, um in local.quota_usage : k => (
      length(um.metric_dimensions) == 0 ? {} : {
        for dk, dv in {
          Type     = um.metric_dimensions[0].type
          Service  = um.metric_dimensions[0].service
          Resource = um.metric_dimensions[0].resource
          Class    = um.metric_dimensions[0].class
        } : dk => dv if dv != null
      }
    )
  }
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

  # Hung here rather than on the alarm because a per-alarm precondition only
  # runs for instances that get created, which is exactly the set that is
  # already fine. This resource always exists, so the check always runs.
  lifecycle {
    precondition {
      condition     = length(local.unmonitorable_quotas) == 0
      error_message = <<-EOT
        These monitored_quotas entries have no CloudWatch usage metric, so an alarm
        on them can never leave INSUFFICIENT_DATA: ${join(", ", local.unmonitorable_quotas)}

        AWS publishes a usage metric for only some quotas. Confirm with:

            aws service-quotas get-service-quota \
              --service-code <svc> --quota-code <code> --query 'Quota.UsageMetric'

        An empty result means CloudWatch cannot see that quota's utilization at
        all. Remove the entry and track it another way, rather than shipping an
        alarm that reports nothing forever.
      EOT
    }
  }
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
  for_each = local.monitorable_quotas

  alarm_name          = "${var.environment}-quota-${each.key}"
  alarm_description   = "Service quota alarm: ${each.value.description} exceeds ${var.quota_threshold_percent}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = data.aws_servicequotas_service_quota.this[each.key].value * var.quota_threshold_percent / 100

  # Every field below is read from the quota's own UsageMetric rather than
  # written here. Hand-writing them produced an alarm that could not match a
  # series: the namespace and metric were hardcoded to AWS/Usage/ResourceCount
  # for all quotas, and the dimensions were built from the Service Quotas API
  # codes — Service = "vpc", Resource = "L-F678F1CE". AWS/Usage dimensions are
  # human-readable names (Service = "EC2", Resource = "VPCsPerRegion"), and a
  # quota code is never a valid dimension value, so with no treat_missing_data
  # the alarm sat in INSUFFICIENT_DATA permanently.
  #
  # Deriving also catches the case hardcoding hid entirely: Lambda's concurrent
  # executions quota does not use AWS/Usage at all. Its usage metric is
  # AWS/Lambda/ConcurrentExecutions with no dimensions.
  namespace   = local.quota_usage[each.key].metric_namespace
  metric_name = local.quota_usage[each.key].metric_name
  statistic   = local.quota_usage[each.key].metric_statistic_recommendation
  period      = 300

  # Empty for an account-wide metric like ConcurrentExecutions, which is correct
  # there rather than a defect. See local.quota_dimensions for why this is
  # filtered on values instead of list length.
  dimensions = local.quota_dimensions[each.key]

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
