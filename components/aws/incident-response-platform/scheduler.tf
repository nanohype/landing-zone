/**
 * EventBridge Scheduler group + role for incident-response's per-incident 15-min
 * nudges. The processor pod's IRSA role calls scheduler:CreateSchedule
 * inside the group when assembling each war room; the schedule's target
 * is the nudge-events SQS queue, invoked via the schedule_role assumed
 * by Scheduler itself.
 *
 * Group + Role isolation is per-environment (incident-response-staging-nudges vs.
 * incident-response-production-nudges). The processor's SCHEDULER_GROUP_NAME +
 * SCHEDULER_ROLE_ARN env vars come from this component's outputs.
 */

resource "aws_scheduler_schedule_group" "nudges" {
  name = "${local.prefix}-nudges"

  tags = local.common_tags
}

resource "aws_iam_role" "schedule_role" {
  name = "${local.prefix}-scheduler-invoke"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:scheduler:${var.region}:${data.aws_caller_identity.current.account_id}:schedule/${aws_scheduler_schedule_group.nudges.name}/*"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "schedule_role_sqs_send" {
  name = "sqs-send"
  role = aws_iam_role.schedule_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["sqs:SendMessage"]
      Resource = [
        aws_sqs_queue.nudge_events.arn,
        aws_sqs_queue.sla_check.arn,
      ]
    }]
  })
}

data "aws_caller_identity" "current" {}
