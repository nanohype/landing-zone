/**
 * Workload identity for digest-pipeline's shared ServiceAccount (used by
 * pipeline, api, and web Deployments in the chart, plus the migrate-job
 * hook).
 *
 * The app's pods run as the operator-reconciled tenant role
 * (`<env>-digest-pipeline-tenant`, minted by the eks-agent-platform operator
 * from the Platform CR). This component binds the chart's ServiceAccount to
 * that role with an EKS Pod Identity association. The permission split
 * across the seam:
 *
 *   - Bedrock model access — operator-owned. The agent-iam tenant baseline
 *     grants invoke; the operator's `bedrock-model-scoping` inline policy
 *     clamps it to Platform.spec.identity.allowedModels.
 *   - Slow-moving substrate (S3, SES, Secrets Manager, CloudWatch) —
 *     tofu-owned, expressed as the app-access managed policy below. The
 *     operator attaches it to the tenant role via
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
  description = "digest-pipeline app-pod substrate grants, attached to the tenant role via Platform.spec.identity.extraPolicyArns"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:PutObject",
        ]
        Resource = [
          aws_s3_bucket.voice_baseline.arn,
          "${aws_s3_bucket.voice_baseline.arn}/*",
          aws_s3_bucket.raw_aggregations.arn,
          "${aws_s3_bucket.raw_aggregations.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail",
          "ses:GetSendQuota",
        ]
        Resource = [
          aws_sesv2_email_identity.digest_pipeline.arn,
          aws_sesv2_configuration_set.digest_pipeline.arn,
        ]
      },
      {
        # Secrets Manager: digest-pipeline/<env>/db-credentials (managed by RDS),
        # plus operator-seeded approvers, workos-directory, grafana-cloud.
        # The chart's ExternalSecret resolves all four.
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:digest-pipeline/${var.environment}/*",
          # RDS master credentials live at the secret-arn the Aurora
          # module manages; pulled by ARN rather than path because the
          # module owns the naming.
          module.aurora.cluster_master_user_secret[0].secret_arn,
        ]
      },
      {
        # Best-effort metrics fallback when OTel isn't reachable.
        # PutMetricData has no resource-level scoping in IAM.
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = ["*"]
      },
    ]
  })

  tags = local.tags
}

# The operator-reconciled tenant role, minted from the Platform CR. Resolved
# by name (the operator's `<env>-<platform>-tenant` contract) so a missing
# Platform fails the plan loudly instead of minting a dangling association.
data "aws_iam_role" "tenant" {
  name = "${var.environment}-digest-pipeline-tenant"
}

# Binds the chart's ServiceAccount to the tenant role through EKS Pod
# Identity — pods receive the role's credentials with no role-arn annotation
# and no OIDC provider involved.
resource "aws_eks_pod_identity_association" "app" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = data.aws_iam_role.tenant.arn

  tags = local.tags
}
