data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  tags = merge(var.tags, {
    Component = "break-glass"
    Team      = var.team
  })
}

################################################################################
# Break-Glass IAM Role
################################################################################

resource "aws_iam_role" "break_glass" {
  name                 = "${var.environment}-break-glass"
  max_session_duration = var.max_session_duration
  permissions_boundary = var.enable_permissions_boundary ? aws_iam_policy.boundary[0].arn : null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = [for id in var.trusted_account_ids : "arn:${local.partition}:iam::${id}:root"]
      }
      Action = "sts:AssumeRole"
      Condition = {
        Bool = {
          "aws:MultiFactorAuthPresent" = "true"
        }
      }
    }]
  })

  tags = merge(local.tags, {
    BreakGlass = "true"
  })
}

resource "aws_iam_role_policy_attachment" "break_glass_admin" {
  role       = aws_iam_role.break_glass.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

################################################################################
# Permissions Boundary
################################################################################

resource "aws_iam_policy" "boundary" {
  count = var.enable_permissions_boundary ? 1 : 0

  name        = "${var.environment}-break-glass-boundary"
  description = "Permissions boundary for break-glass role — prevents IAM/STS/Orgs modifications"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowAll"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      },
      {
        # The ceiling on the emergency admin. Beyond the identity-mint verbs, this
        # Deny closes the session-persistence and privilege-escalation paths a
        # broken-glass session could otherwise use to outlive the incident:
        # minting an access key, attaching/inlining a user policy, publishing a new
        # default policy version, rewriting a role's trust to make it self-
        # assumable, stripping/replacing a role's permissions boundary, or chaining
        # into another role via sts:AssumeRole. None survive the glass being reset.
        Sid    = "DenyIAMModifications"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:CreateAccessKey",
          "iam:AttachUserPolicy",
          "iam:PutUserPolicy",
          "iam:CreatePolicyVersion",
          "iam:UpdateAssumeRolePolicy",
          # BOTH boundary verbs. Put REPLACES a boundary, Delete STRIPS it, and
          # denying only Put leaves the ceiling removable in one call from an
          # AdministratorAccess session — which is the session this boundary
          # exists to cap. The three sibling boundaries in this repo (fleet-vend,
          # fleet-hub, fleet-unwedge) deny both.
          "iam:PutRolePermissionsBoundary",
          "iam:DeleteRolePermissionsBoundary",
          "sts:AssumeRole",
          "organizations:*",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.tags
}

################################################################################
# CloudWatch Alarm on Break-Glass Usage
################################################################################

resource "aws_cloudwatch_log_group" "break_glass" {
  name              = "/${var.environment}/break-glass"
  retention_in_days = 365

  tags = local.tags
}

resource "aws_kms_key" "break_glass" {
  description             = "${var.environment} break-glass alert topic encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  # CloudWatch Alarms and EventBridge publish the assumption alert; SSE-SNS makes
  # SNS call kms:GenerateDataKey*/Decrypt as those service principals, so the key
  # policy must admit them or the alert never fires. They are separate statements
  # because only one of the two populates condition context — see below.
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
      {
        Sid       = "AllowAlarmPublish"
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
      {
        # Unconditioned, matching the observability component's key policy. AWS
        # does not document whether EventBridge populates condition context on
        # the KMS call it makes to encrypt into an SSE-KMS topic, and an
        # unpopulated key fails closed — the alert is accepted and dropped with
        # no error at the rule. The guard would also buy nothing: the topic's own
        # resource policy is the boundary for who may publish, and that policy
        # cannot be conditioned for this principal at all, so a condition on the
        # key cannot restrict what the topic already admits.
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

  tags = local.tags
}

resource "aws_kms_alias" "break_glass" {
  name          = "alias/${var.environment}-break-glass-alert"
  target_key_id = aws_kms_key.break_glass.key_id
}

resource "aws_sns_topic" "break_glass" {
  name              = "${var.environment}-break-glass-alert"
  kms_master_key_id = aws_kms_key.break_glass.arn

  tags = local.tags
}

resource "aws_sns_topic_subscription" "break_glass_email" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.break_glass.arn
  protocol  = "email"
  endpoint  = each.value
}

# Break-glass detection is the EventBridge rule below, not a CloudWatch alarm.
# Nothing in this org writes Custom/Security/BreakGlassAssumeRole — no
# PutMetricData caller, no metric filter, no EMF emitter — so an alarm on it
# could never fire. With treat_missing_data "notBreaching" it would not even
# show INSUFFICIENT_DATA: it would sit in OK and read as "the break-glass role
# has not been assumed", which is the most dangerous way for a security control
# to be wrong.

################################################################################
# EventBridge Rule for Break-Glass Detection
################################################################################

resource "aws_cloudwatch_event_rule" "break_glass" {
  name        = "${var.environment}-break-glass-detection"
  description = "Detect break-glass role assumption"

  event_pattern = jsonencode({
    source      = ["aws.sts"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["AssumeRole"]
      requestParameters = {
        roleArn = [aws_iam_role.break_glass.arn]
      }
    }
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "break_glass_sns" {
  rule = aws_cloudwatch_event_rule.break_glass.name
  arn  = aws_sns_topic.break_glass.arn
}

resource "aws_sns_topic_policy" "break_glass_eventbridge" {
  arn = aws_sns_topic.break_glass.arn

  # No Condition, deliberately, and this is the security control's own paging
  # path so the reason matters here more than anywhere. AWS documents that
  # EventBridge does not populate condition context on the SNS publish path —
  # "You can't use Condition blocks in Amazon SNS topic policies for
  # EventBridge" — so an aws:SourceAccount or aws:SourceArn guard here never
  # evaluates true and the statement never allows. The rule reports success and
  # the message is dropped, with the only trace a FailedInvocations counter:
  # a break-glass assumption that pages nobody.
  #
  # The residual exposure a guard would have covered — the events service
  # principal acting for another account's rule — is bounded by the topic ARN
  # this statement names and is watched by the FailedInvocations alarm below,
  # which rides the CloudWatch principal and therefore does evaluate its guard.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridge"
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "SNS:Publish"
      Resource = aws_sns_topic.break_glass.arn
    }]
  })
}

# A break-glass assumption that EventBridge accepts and then fails to deliver is
# the worst state this component has: the role was used and nobody was told.
# FailedInvocations is emitted by EventBridge, not by the SNS path that failed,
# and this alarm publishes through cloudwatch.amazonaws.com, whose grant on both
# the topic and the CMK does evaluate its aws:SourceAccount guard — so the
# watcher does not share the failure mode it watches.
resource "aws_cloudwatch_metric_alarm" "break_glass_delivery_failed" {
  alarm_name          = "${var.environment}-break-glass-delivery-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FailedInvocations"
  namespace           = "AWS/Events"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "The break-glass detection rule failed to deliver to its alert topic — a role assumption may have gone unannounced."
  alarm_actions       = [aws_sns_topic.break_glass.arn]

  # A rule that has never fired publishes no FailedInvocations datapoints at all,
  # so `missing` is the correct reading of absence here: no invocations means no
  # failed invocations. Treating it as breaching would page continuously in the
  # steady state this control is designed to sit in.
  treat_missing_data = "missing"

  dimensions = {
    RuleName = aws_cloudwatch_event_rule.break_glass.name
  }

  tags = local.tags
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "break_glass_role_arn" {
  name  = "/${var.environment}/break-glass/role-arn"
  type  = "String"
  value = aws_iam_role.break_glass.arn

  tags = local.tags
}
