/**
 * IRSA role for competitive-intelligence's ServiceAccount. One
 * consolidated inline policy covers every action the Platform CR's
 * placeholder ARNs reference.
 *
 * The eks-agent-platform operator reconciles this role's ARN onto the
 * chart's ServiceAccount's eks.amazonaws.com/role-arn annotation.
 */

module "competitive_intelligence_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name         = "${local.prefix}-platform"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_issuer       = var.oidc_issuer
  namespace         = var.namespace
  service_account   = var.service_account

  policy_statements = [
    {
      # Converse uses InvokeModel + InvokeModelWithResponseStream.
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
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
      # Secrets Manager: app-secrets (Slack + optional LLM API
      # credentials) and the Aurora-managed master credentials secret.
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:competitive-intelligence/${var.environment}/*",
        module.aurora.cluster_master_user_secret[0].secret_arn,
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
