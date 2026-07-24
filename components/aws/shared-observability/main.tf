# shared-observability — the fleet-wide destination for alarm delivery.
#
# A shared-services account runs one set of severity-routed SNS topics
# (critical / warning / info) that every workload account's CloudWatch alarms
# publish to directly, so a fleet-wide on-call watches one topic set instead of
# one per cluster. Alarm *definitions* stay local to the resources they watch
# (they reference local ARNs and dimensions); only the *destination* centralizes.
#
# Cross-account publish is authorized by org membership, not an account list: the
# topic policies and the topics' CMK admit the CloudWatch service principal under
# an aws:SourceOrgID condition. That is the maintenance win — adding a workload
# account needs no edit here, which is exactly the grant that otherwise breaks
# alarm delivery silently as the fleet grows. Note the key: a *service* principal
# acting cross-account populates aws:SourceOrgID (the org of the resource it acts
# for), not aws:PrincipalOrgID (which scopes IAM-principal callers).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  tags = merge(var.tags, {
    Component = "shared-observability"
    Team      = var.team
  })

  severities = ["critical", "warning", "info"]
}

################################################################################
# Central alert CMK — org-scoped for cross-account CloudWatch
################################################################################

resource "aws_kms_key" "alerts" {
  description             = "${var.name_prefix} fleet alert topic encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      # Any workload account's CloudWatch, publishing an alarm to a central topic,
      # calls kms:GenerateDataKey* on this key. aws:SourceOrgID confines that to
      # the org — a service principal acting for a resource inside this org — with
      # no per-account grant to maintain.
      {
        Sid       = "AllowOrgCloudWatchUseKey"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:SourceOrgID" = var.organization_id } }
      },
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "alerts" {
  name          = "alias/${var.name_prefix}-fleet-alerts"
  target_key_id = aws_kms_key.alerts.key_id
}

################################################################################
# Central severity-routed topics
################################################################################

resource "aws_sns_topic" "this" {
  for_each = toset(local.severities)

  name              = "${var.name_prefix}-fleet-alerts-${each.key}"
  kms_master_key_id = aws_kms_key.alerts.arn
  tags              = merge(local.tags, { Severity = each.key })
}

# Admit CloudWatch alarms from any account in the org to publish, and only this
# org. This is the topic side of the cross-account grant; the CMK policy is the
# key side. Both ride aws:SourceOrgID so the fleet grows without an edit here.
resource "aws_sns_topic_policy" "this" {
  for_each = aws_sns_topic.this

  arn = each.value.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowOrgCloudWatchPublish"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = each.value.arn
      Condition = { StringEquals = { "aws:SourceOrgID" = var.organization_id } }
    }]
  })
}

# Fleet on-call email subscriptions, applied to the critical and warning topics
# (info is for dashboards/automation, not a page). Empty by default.
resource "aws_sns_topic_subscription" "email" {
  for_each = {
    for pair in setproduct(["critical", "warning"], var.alert_email_endpoints) :
    "${pair[0]}:${pair[1]}" => { severity = pair[0], endpoint = pair[1] }
  }

  topic_arn = aws_sns_topic.this[each.value.severity].arn
  protocol  = "email"
  endpoint  = each.value.endpoint
}

################################################################################
# Discovery — the central topic ARNs workload observability adopts
################################################################################

resource "aws_ssm_parameter" "topic_arns" {
  for_each = aws_sns_topic.this

  name  = "/${var.environment}/shared-observability/topic-${each.key}-arn"
  type  = "String"
  value = each.value.arn
  tags  = local.tags
}
