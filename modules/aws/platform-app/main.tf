/**
 * platform-app — the shared Pod Identity + app-access shell every single-tenant
 * `<app>-platform` component binds through.
 *
 * Each `<app>-platform` component provisions its own bespoke substrate (DDB,
 * SQS, S3, RDS, KMS, SES, ...) and hands the resulting IAM statements here. This
 * module is the identical half those components share:
 *
 *   - the `<environment>-<app>-app-access` managed policy that wraps the app's
 *     substrate statements — attached to the tenant role by the operator via
 *     Platform.spec.identity.extraPolicyArns, never here,
 *   - the lookup of the operator-reconciled `<environment>-<app>-tenant` role
 *     (resolved by name so a missing Platform fails the plan loudly instead of
 *     minting a dangling association),
 *   - the EKS Pod Identity association binding the app's ServiceAccount to that
 *     role — pods receive the role's credentials with no role-arn annotation and
 *     no OIDC provider involved.
 *
 * The permission split across the seam is fixed: Bedrock model access is
 * operator-owned (agent-iam grants invoke; the operator clamps it to
 * Platform.spec.identity.allowedModels), so it never appears in
 * var.policy_statements. Only slow-moving substrate grants belong here.
 *
 * Ordering contract: the Platform CR must be Ready (tenant role minted) before
 * the association can apply. Sequence: docs/runbooks/model-access-cutover.md.
 */

resource "aws_iam_policy" "app_access" {
  name        = "${var.environment}-${var.app_name}-app-access"
  path        = "/eks-agent-platform/"
  description = "${var.app_name} app-pod substrate grants, attached to the tenant role via Platform.spec.identity.extraPolicyArns"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = var.policy_statements
  })

  tags = var.tags
}

data "aws_iam_role" "tenant" {
  name = "${var.environment}-${var.app_name}-tenant"
}

resource "aws_eks_pod_identity_association" "app" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = data.aws_iam_role.tenant.arn

  tags = var.tags
}
