/**
 * IRSA role for almanac's shared ServiceAccount (used by both the main
 * application pod and the audit-consumer Deployment). One consolidated
 * inline policy covers every action the Platform CR's placeholder ARNs
 * reference.
 *
 * The eks-agent-platform operator reconciles this role's ARN onto the
 * chart's ServiceAccount's eks.amazonaws.com/role-arn annotation.
 */

module "almanac_irsa" {
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
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
      ]
      Resource = [
        # Claude Sonnet 4.6 — cross-region inference profile + foundation
        # model ARNs (both needed because the profile fans out to FM ARNs
        # across regions)
        "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-sonnet-4-6*",
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6*",
        # Titan embeddings for query vectors
        "arn:aws:bedrock:${var.region}::foundation-model/amazon.titan-embed-text-v2*",
      ]
    },
    {
      # Secrets Manager: app-secrets (Slack, WorkOS, per-source OAuth
      # client credentials), db-credentials (RDS master credentials
      # managed by the rds-aurora module), grafana-cloud OTLP auth.
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:almanac/${var.environment}/*",
      ]
    },
    {
      # Best-effort metrics from the in-app metrics surface (timing +
      # counter) when OTel isn't available — fallback CloudWatch path.
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = ["*"]
    },
  ]

  tags = local.common_tags
}
