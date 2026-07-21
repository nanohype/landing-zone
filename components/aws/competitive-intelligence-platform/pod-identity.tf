/**
 * Workload identity for competitive-intelligence's ServiceAccount (the
 * radar's worker pod).
 *
 * The app's pods run as the operator-reconciled tenant role
 * (`<env>-competitive-intelligence-tenant`, minted by the eks-agent-platform
 * operator from the Platform CR). This component binds the chart's
 * ServiceAccount to that role with an EKS Pod Identity association. The
 * permission split across the seam:
 *
 *   - Bedrock model access — operator-owned. The agent-iam tenant baseline
 *     grants invoke; the operator's `bedrock-model-scoping` inline policy
 *     clamps it to Platform.spec.identity.allowedModels.
 *   - Slow-moving substrate (Secrets Manager, CloudWatch) — tofu-owned,
 *     expressed as the app-access managed policy below. The operator
 *     attaches it to the tenant role via
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

  app_name        = "competitive-intelligence"
  environment     = var.environment
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  tags            = local.tags

  policy_statements = [
    {
      # Secrets Manager: app-secrets (Slack + optional LLM API
      # credentials) and the Aurora-managed master credentials secret.
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:competitive-intelligence/${var.environment}/*",
        module.aurora.cluster_master_user_secret[0].secret_arn,
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
