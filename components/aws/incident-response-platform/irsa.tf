/**
 * IRSA role for incident-response's shared ServiceAccount (used by both webhook and
 * processor Deployments in the chart). The role bundles every permission
 * the Platform CR's placeholder ARNs reference into one inline policy.
 *
 * The eks-agent-platform operator reconciles the chart's ServiceAccount's
 * eks.amazonaws.com/role-arn annotation from this role's ARN — emitted as
 * an output below for the operator-side wiring layer to consume.
 */

module "incident_response_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name         = "${local.prefix}-platform"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_issuer       = var.oidc_issuer
  namespace         = var.namespace
  service_account   = var.service_account

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
        "arn:aws:scheduler:${var.region}:${data.aws_caller_identity.current.account_id}:schedule/${aws_scheduler_schedule_group.nudges.name}/*",
      ]
    },
    {
      # PassRole on the Scheduler's invoke-role — Scheduler assumes this
      # when firing a nudge target, but the call site (processor pod) needs
      # iam:PassRole on it to attach it during CreateSchedule.
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = [aws_iam_role.schedule_role.arn]
    },
    {
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
      ]
      Resource = [
        "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-sonnet-4-6*",
        "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-haiku-4-5*",
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6*",
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5*",
      ]
    },
    {
      # Secrets Manager reads — incident-response seeds these via scripts/seed-secrets.sh
      # before any deploy; the chart's ExternalSecret pulls them at runtime.
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:incident-response/${var.environment}/*",
      ]
    },
    {
      # Best-effort metrics from the in-app MetricsEmitter.
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = ["*"]
    },
  ]

  tags = local.common_tags
}
