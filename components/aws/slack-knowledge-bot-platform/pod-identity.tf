/**
 * Workload identity for slack-knowledge-bot's shared ServiceAccount (used by
 * both the main application pod and the audit-consumer Deployment).
 *
 * The app's pods run as the operator-reconciled tenant role
 * (`<env>-slack-knowledge-bot-tenant`, minted by the eks-agent-platform
 * operator from the Platform CR). This component binds the chart's
 * ServiceAccount to that role with an EKS Pod Identity association. The
 * permission split across the seam:
 *
 *   - Bedrock model access — operator-owned. The agent-iam tenant baseline
 *     grants invoke; the operator's `bedrock-model-scoping` inline policy
 *     clamps it to Platform.spec.identity.allowedModels.
 *   - Slow-moving substrate (DynamoDB, SQS, S3, KMS, Secrets Manager,
 *     CloudWatch) — tofu-owned, expressed as the app-access managed policy
 *     below. The operator attaches it to the tenant role via
 *     Platform.spec.identity.extraPolicyArns.
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

  app_name        = "slack-knowledge-bot"
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
        aws_dynamodb_table.tokens.arn,
        aws_dynamodb_table.audit.arn,
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
        aws_sqs_queue.audit.arn,
        aws_sqs_queue.audit_dlq.arn,
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
      # Envelope encryption for per-user OAuth tokens. EncryptionContext
      # binding (userId+provider) is enforced application-side; this
      # policy just gates Encrypt/Decrypt on the right key ARN.
      Effect = "Allow"
      Action = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      Resource = [aws_kms_key.token_store.arn]
    },
    {
      # Secrets Manager: app-secrets (Slack, WorkOS, per-source OAuth
      # client credentials), db-credentials (RDS master credentials
      # managed by the rds-aurora module), grafana-cloud OTLP auth.
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:slack-knowledge-bot/${var.environment}/*",
      ]
    },
    {
      # Best-effort metrics from the in-app metrics surface (timing +
      # counter) when OTel isn't available — fallback CloudWatch path.
      # PutMetricData has no resource-level scoping in IAM.
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = ["*"]
    },
  ]
}
