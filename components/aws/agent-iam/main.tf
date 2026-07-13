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

  # Per-Platform session role, created by the operator's Platform controller from
  # spec.attribution (operators + sessionRoleMaxDurationSeconds). Named
  # <env>-<platform>-session at the ROOT path — not under the tenant path — so the
  # tenant statements above do not cover it and the operator could not manage the
  # role its own controller creates. Same name-scoped shape as tenant_role_name_arn.
  platform_session_role_arn = "arn:${local.partition}:iam::${local.account_id}:role/${var.environment}-*-session"

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
        # The tenant role serves every workload class in a Platform's
        # namespace: the app's chart pods (bound by the <app>-platform
        # component's Pod Identity association, granted through the
        # app-access policy in spec.identity.extraPolicyArns) and AgentFleet
        # pods (tenant-runtime SA). The ceiling therefore covers the union of
        # substrate services those workloads touch — DynamoDB stores, SQS
        # queues, SES sends, EventBridge Scheduler CRUD, KMS envelope
        # encryption — on top of the Bedrock + telemetry core. Actual grants
        # are resource-scoped in the attached policies; this is only the cap.
        Sid    = "TenantWorkloadCeiling"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
          "bedrock:ApplyGuardrail",
          "bedrock:GetGuardrail",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "ses:SendEmail",
          "ses:SendRawEmail",
          "ses:GetSendQuota",
          "scheduler:CreateSchedule",
          "scheduler:GetSchedule",
          "scheduler:UpdateSchedule",
          "scheduler:DeleteSchedule",
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ChangeMessageVisibility",
          "kms:Encrypt",
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
        # EventBridge Scheduler targets fire through a scheduler-invoke role
        # the target's component provisions; CreateSchedule requires
        # iam:PassRole on it. Cap that pass to scheduler-invoke roles handed
        # to the Scheduler service — nothing else, nowhere else.
        Sid      = "SchedulerInvokeRolePass"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/*-scheduler-invoke"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "scheduler.amazonaws.com"
          }
        }
      },
      {
        # Hard ceiling: no tenant role may ever touch org/account settings
        # or assume another role — the privilege-escalation vectors.
        Sid    = "DenyEscalation"
        Effect = "Deny"
        Action = [
          "organizations:*",
          "account:*",
          "sts:AssumeRole",
        ]
        Resource = "*"
      },
      {
        # IAM is denied wholesale except on scheduler-invoke roles, where the
        # Allow above (PassRole, scheduler.amazonaws.com only) sets the
        # ceiling. NotResource keeps the deny airtight for every other IAM
        # surface — a tenant role can never mint, modify, or read identities.
        Sid         = "DenyIamOutsideSchedulerInvokePass"
        Effect      = "Deny"
        Action      = ["iam:*"]
        NotResource = "arn:${local.partition}:iam::${local.account_id}:role/*-scheduler-invoke"
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

  # Fleet vends pass the vend/hub boundary here — the fleet roles' CreateRole
  # gate requires the operator role to carry the ceiling of whichever role is
  # minting it. Empty = no boundary (direct terragrunt applies).
  permissions_boundary = var.operator_permissions_boundary_arn != "" ? var.operator_permissions_boundary_arn : null

  tags = local.tags
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
        # The Platform controller calls ensureBucketPolicy() on the model-artifacts
        # bucket on every reconcile: it reads the current bucket policy and writes
        # back one granting each Platform's tenant roles access to their own prefix.
        # The operator's policy carried no S3 statement at all, so every reconcile
        # failed with AccessDenied on s3:GetBucketPolicy and the Platform never left
        # phase=Provisioning.
        #
        # Bucket-policy verbs only, and only on the two buckets this component owns.
        # Object-level access is deliberately NOT granted here — the operator brokers
        # the buckets, it does not read or write their contents; the tenant roles it
        # writes the policy for do that.
        # Read + lifecycle the per-Platform session role. iam:UpdateRole is required
        # for MaxSessionDuration, which is what spec.attribution.sessionRoleMaxDurationSeconds
        # sets — the operator was failing here with AccessDenied on iam:GetRole
        # dev-ops-session and every Platform hung in phase=Provisioning.
        Sid    = "PlatformSessionRoleRead"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:DeleteRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:GetRolePolicy",
        ]
        Resource = local.platform_session_role_arn
      },
      {
        # Creating the session role is gated on the permissions boundary, exactly as
        # tenant role creation is. The operator may mint a role a human then assumes;
        # it must never be able to mint one that outranks the boundary. An unbounded
        # iam:CreateRole here would be a privilege-escalation path straight through
        # the operator.
        Sid    = "PlatformSessionRoleWriteWithBoundary"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
        ]
        Resource = local.platform_session_role_arn
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = aws_iam_policy.tenant_boundary.arn
          }
        }
      },
      {
        Sid    = "ArtifactBucketPolicy"
        Effect = "Allow"
        Action = [
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy",
        ]
        Resource = [
          aws_s3_bucket.model_artifacts.arn,
          aws_s3_bucket.eval_reports.arn,
        ]
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
