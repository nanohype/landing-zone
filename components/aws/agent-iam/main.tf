################################################################################
# agent-iam — the AWS IAM substrate for the eks-agent-platform operator.
#
# Provisions: the operator's own IRSA role (scoped to mint per-tenant roles
# under a fixed path, gated by a permissions boundary), the tenant permissions
# boundary (the ceiling for every tenant role), the tenant baseline managed
# policy, and the SSM parameters the operator reads at startup
# (/eks-agent-platform/<env>/agent-iam/*).
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  partition        = data.aws_partition.current.partition
  irsa_role_prefix = "${var.environment}-eks-agent-platform"

  # Path every tenant role is minted under. The operator's IAM permissions are
  # scoped to this path so it can never touch roles outside it. Matches the
  # operator default (controller.tenantRoleName / TenantIAMPath).
  tenant_role_path = "/eks-agent-platform/tenants/"
  tenant_role_arn  = "arn:${local.partition}:iam::${local.account_id}:role${local.tenant_role_path}*"

  # The operator's idempotency GetRole runs before the role exists, so IAM
  # authorizes against the bare-name ARN (root path) rather than the path ARN.
  # Allow the tenant-role name pattern (<env>-*-tenant) so that pre-create
  # GetRole resolves to NoSuchEntity instead of AccessDenied.
  tenant_role_name_arn = "arn:${local.partition}:iam::${local.account_id}:role/${var.environment}-*-tenant"

  ssm_prefix = "/eks-agent-platform/${var.environment}/agent-iam"

  tags = merge(var.tags, {
    Component = "agent-iam"
    Team      = var.team
  })
}

################################################################################
# Tenant permissions boundary — the maximum privileges any tenant role can
# ever have, regardless of what managed policies get attached. The operator is
# only allowed to create/modify tenant roles that carry this boundary, so a
# Platform CR cannot escalate a tenant role beyond this ceiling.
################################################################################

resource "aws_iam_policy" "tenant_boundary" {
  name        = "${local.irsa_role_prefix}-tenant-boundary"
  path        = "/eks-agent-platform/"
  description = "Permissions boundary ceiling for eks-agent-platform tenant roles"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TenantWorkloadCeiling"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
          "bedrock:ApplyGuardrail",
          "bedrock:GetGuardrail",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "logs:CreateLogStream",
          "logs:CreateLogGroup",
          "logs:PutLogEvents",
          "cloudwatch:PutMetricData",
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
        ]
        Resource = "*"
      },
      {
        # Hard ceiling: no tenant role may ever touch IAM, org/account
        # settings, or assume another role — the privilege-escalation vectors.
        Sid    = "DenyEscalation"
        Effect = "Deny"
        Action = [
          "iam:*",
          "organizations:*",
          "account:*",
          "sts:AssumeRole",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.tags
}

################################################################################
# Tenant baseline managed policy — attached to every tenant role by the
# operator (TenantBaselinePolicyARN). The minimal common grant: invoke Bedrock
# through guardrails + ship logs/traces. Per-tenant extras (S3 bucket, secrets,
# queues) are layered on via the per-tenant <app>-platform components, always
# under the boundary above.
################################################################################

resource "aws_iam_policy" "tenant_baseline" {
  name        = "${local.irsa_role_prefix}-tenant-baseline"
  path        = "/eks-agent-platform/"
  description = "Baseline policy attached to every eks-agent-platform tenant role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
          "bedrock:ApplyGuardrail",
        ]
        Resource = "*"
      },
      {
        Sid    = "Telemetry"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.tags
}

################################################################################
# Operator IRSA role — assumed by the operator pod (SA
# eks-agent-platform/operator). Scoped to manage tenant roles ONLY under the
# tenant path, and only roles carrying the permissions boundary.
################################################################################

data "aws_iam_policy_document" "operator_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:sub"
      values   = ["system:serviceaccount:eks-agent-platform:operator"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "operator" {
  name               = "${local.irsa_role_prefix}-operator"
  path               = "/eks-agent-platform/"
  assume_role_policy = data.aws_iam_policy_document.operator_trust.json
  description        = "IRSA role for the eks-agent-platform operator"
  tags               = local.tags
}

resource "aws_iam_role_policy" "operator" {
  name = "operator"
  role = aws_iam_role.operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TenantRoleRead"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:DeleteRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:GetRolePolicy",
          "iam:UpdateAssumeRolePolicy",
        ]
        Resource = [local.tenant_role_arn, local.tenant_role_name_arn]
      },
      {
        # Create + modify tenant roles ONLY when they carry the permissions
        # boundary — the privilege-escalation guard.
        Sid    = "TenantRoleWriteWithBoundary"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
        ]
        Resource = local.tenant_role_arn
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = aws_iam_policy.tenant_boundary.arn
          }
        }
      },
      {
        # Create + manage the EKS Pod Identity associations that bind each
        # tenant ServiceAccount (tenant-runtime) to its role. Scoped to this
        # environment's cluster + its association resources.
        Sid    = "TenantPodIdentityAssociations"
        Effect = "Allow"
        Action = [
          "eks:CreatePodIdentityAssociation",
          "eks:DeletePodIdentityAssociation",
          "eks:DescribePodIdentityAssociation",
          "eks:ListPodIdentityAssociations",
          "eks:UpdatePodIdentityAssociation",
        ]
        Resource = [
          "arn:${local.partition}:eks:${var.region}:${local.account_id}:cluster/${var.environment}-*",
          "arn:${local.partition}:eks:${var.region}:${local.account_id}:podidentityassociation/${var.environment}-*/*",
        ]
      },
      {
        # CreatePodIdentityAssociation requires iam:PassRole on the tenant role,
        # constrained to the EKS Pod Identity service principal.
        Sid      = "PassTenantRoleToPodIdentity"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = local.tenant_role_arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "pods.eks.amazonaws.com"
          }
        }
      },
      {
        Sid    = "KMSGrants"
        Effect = "Allow"
        Action = [
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant",
          "kms:DescribeKey",
        ]
        Resource = "arn:${local.partition}:kms:${var.region}:${local.account_id}:key/*"
      },
      {
        Sid    = "SSMRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/eks-agent-platform/*"
      },
      {
        Sid      = "KillSwitchEvents"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = "arn:${local.partition}:events:${var.region}:${local.account_id}:event-bus/*"
      },
    ]
  })
}

################################################################################
# SSM parameters the operator reads at startup
# (/eks-agent-platform/<env>/agent-iam/*).
################################################################################

resource "aws_ssm_parameter" "operator_role_arn" {
  name  = "${local.ssm_prefix}/operator_role_arn"
  type  = "String"
  value = aws_iam_role.operator.arn
  tags  = local.tags
}

# Published alongside the ARN so consumers that must attach a policy to the
# operator role (e.g. the cost-pipeline operator-read grant) or name it in an
# inline policy can resolve the role name without parsing the ARN.
resource "aws_ssm_parameter" "operator_role_name" {
  name  = "${local.ssm_prefix}/operator_role_name"
  type  = "String"
  value = aws_iam_role.operator.name
  tags  = local.tags
}

resource "aws_ssm_parameter" "tenant_iam_path" {
  name  = "${local.ssm_prefix}/tenant_iam_path"
  type  = "String"
  value = local.tenant_role_path
  tags  = local.tags
}

resource "aws_ssm_parameter" "tenant_baseline_policy_arn" {
  name  = "${local.ssm_prefix}/tenant_baseline_policy_arn"
  type  = "String"
  value = aws_iam_policy.tenant_baseline.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "tenant_permissions_boundary_arn" {
  name  = "${local.ssm_prefix}/tenant_permissions_boundary_arn"
  type  = "String"
  value = aws_iam_policy.tenant_boundary.arn
  tags  = local.tags
}
