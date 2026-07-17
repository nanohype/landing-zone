/**
 * Workload identity for incident-response's shared ServiceAccount (used by
 * both webhook and processor Deployments in the chart).
 *
 * The app's pods run as the operator-reconciled tenant role
 * (`<env>-incident-response-tenant`, minted by the eks-agent-platform
 * operator from the Platform CR). This component binds the chart's
 * ServiceAccount to that role with an EKS Pod Identity association. The
 * permission split across the seam:
 *
 *   - Bedrock model access — operator-owned. The agent-iam tenant baseline
 *     grants invoke; the operator's `bedrock-model-scoping` inline policy
 *     clamps it to Platform.spec.identity.allowedModels.
 *   - Slow-moving substrate (DynamoDB, SQS, S3, EventBridge Scheduler,
 *     Secrets Manager, CloudWatch) — tofu-owned, expressed as the
 *     app-access managed policy below. The operator attaches it to the
 *     tenant role via Platform.spec.identity.extraPolicyArns.
 *
 * Ordering contract: the Platform CR must be Ready (tenant role minted)
 * before this component's association can apply. Sequence:
 * docs/runbooks/model-access-cutover.md.
 */

# Pod Identity + app-access shell (managed policy, tenant-role lookup, and the
# EKS Pod Identity association) is the shared platform-app module. Only the
# app-specific substrate statements below are bespoke.
module "platform_app" {
  source = "../../../modules/aws/platform-app"

  app_name        = "incident-response"
  environment     = var.environment
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  tags            = local.tags

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:BatchGetItem",
        "dynamodb:BatchWriteItem",
      ]
      Resource = [
        aws_dynamodb_table.incidents.arn,
        "${aws_dynamodb_table.incidents.arn}/index/*",
        aws_dynamodb_table.audit.arn,
        "${aws_dynamodb_table.audit.arn}/index/*",
        aws_dynamodb_table.identity_cache.arn,
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ChangeMessageVisibility",
      ]
      Resource = [
        aws_sqs_queue.incident_events.arn,
        aws_sqs_queue.incident_events_dlq.arn,
        aws_sqs_queue.nudge_events.arn,
        aws_sqs_queue.nudge_events_dlq.arn,
        aws_sqs_queue.sla_check.arn,
        aws_sqs_queue.sla_check_dlq.arn,
      ]
    },
    {
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.audit.arn,
        "${aws_s3_bucket.audit.arn}/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "scheduler:CreateSchedule",
        "scheduler:GetSchedule",
        "scheduler:UpdateSchedule",
        "scheduler:DeleteSchedule",
      ]
      Resource = [
        "arn:aws:scheduler:${var.region}:${local.account_id}:schedule/${aws_scheduler_schedule_group.nudges.name}/*",
      ]
    },
    {
      # PassRole on the Scheduler's invoke-role — Scheduler assumes this
      # when firing a nudge target, but the call site (processor pod) needs
      # iam:PassRole on it to attach it during CreateSchedule. The tenant
      # permissions boundary caps this to *-scheduler-invoke roles passed
      # to scheduler.amazonaws.com (agent-iam SchedulerInvokeRolePass).
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = [aws_iam_role.schedule_role.arn]
    },
    {
      # Secrets Manager reads — incident-response seeds these via scripts/seed-secrets.sh
      # before any deploy; the chart's ExternalSecret pulls them at runtime.
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:incident-response/${var.environment}/*",
      ]
    },
    {
      # Best-effort metrics from the in-app MetricsEmitter.
      # PutMetricData has no resource-level scoping in IAM.
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = ["*"]
    },
  ]
}
