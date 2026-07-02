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

# Slow-moving substrate grants for the app pods. Attached to the tenant role
# by the operator (Platform.spec.identity.extraPolicyArns), never here — the
# tenant role's attachment set is operator-reconciled state.
resource "aws_iam_policy" "app_access" {
  name        = "${local.prefix}-app-access"
  path        = "/eks-agent-platform/"
  description = "competitive-intelligence app-pod substrate grants, attached to the tenant role via Platform.spec.identity.extraPolicyArns"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
        # PutMetricData has no resource-level scoping in IAM.
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = ["*"]
      },
    ]
  })

  tags = local.common_tags
}

# The operator-reconciled tenant role, minted from the Platform CR. Resolved
# by name (the operator's `<env>-<platform>-tenant` contract) so a missing
# Platform fails the plan loudly instead of minting a dangling association.
data "aws_iam_role" "tenant" {
  name = "${var.environment}-competitive-intelligence-tenant"
}

# Binds the chart's ServiceAccount to the tenant role through EKS Pod
# Identity — pods receive the role's credentials with no role-arn annotation
# and no OIDC provider involved.
resource "aws_eks_pod_identity_association" "app" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = data.aws_iam_role.tenant.arn

  tags = local.common_tags
}
