################################################################################
# fleet-vend — the cross-account role the eks-fleet hub assumes to provision an
# EKS cluster in THIS workload account.
#
# The management-account Crossplane role (eks-fleet-crossplane) sts:AssumeRoles
# this role; the cluster-stack entrypoint then runs as it to stand up the
# network + cluster. The vend role carries a permissions boundary that is the hard
# escalation ceiling (it can't mint users, touch org/account, strip boundaries, or
# widen itself), and its identity policy is PATH-SCOPED: it may only create/modify
# the cluster's IAM roles + policies under /eks-fleet/. The role ARN is published
# to SSM for the hub/portal to discover.
#
# CONTRACT: the cluster-stack entrypoint sets cluster_iam_role_path = "/eks-fleet/"
# for cross-account vends (terraform-aws-eks / karpenter / workload-identity all
# create their roles under that path), which is what satisfies this role's path
# gate. No per-role permissions boundary is required — the vend role's own boundary
# is the ceiling. (The vend boundary ARN is still published to SSM so the gate can
# be re-tightened to require a per-role boundary later without rewiring.)
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  role_prefix = "${var.environment}-eks-fleet"
  iam_path    = "/eks-fleet/"
  ssm_prefix  = "/eks-fleet/${var.environment}/fleet-vend"

  vend_role_name = "${local.role_prefix}-vend"
  vend_role_arn  = "arn:${local.partition}:iam::${local.account_id}:role${local.iam_path}${local.vend_role_name}"

  # Roles/policies/instance-profiles the vend role is allowed to manage — only
  # those minted under the eks-fleet path. Pre-create GetRole must also resolve
  # against the bare-name ARN (root path), so allow that pattern for reads.
  managed_role_arn          = "arn:${local.partition}:iam::${local.account_id}:role${local.iam_path}*"
  managed_role_name_arn     = "arn:${local.partition}:iam::${local.account_id}:role/${local.role_prefix}-*"
  managed_policy_arn        = "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}*"
  managed_instance_prof_arn = "arn:${local.partition}:iam::${local.account_id}:instance-profile${local.iam_path}*"

  # Karpenter (v1) mints its node instance profile at the ROOT path as
  # <cluster>_<hash>; the EKS cluster name is env-prefixed (see cluster-stack),
  # so every Karpenter profile in this account shares the ${var.environment}-
  # prefix. The vend role never creates these — but at teardown (after Karpenter
  # is uninstalled) it must detach + delete them to drop the node role, which
  # falls outside the /eks-fleet/ path.
  managed_karpenter_instance_prof_arn = "arn:${local.partition}:iam::${local.account_id}:instance-profile/${var.environment}-*"

  # agent-iam provisioning surface — the eks-agent-platform operator IRSA role, the
  # two tenant managed policies, and the operator-startup SSM params all land under
  # /eks-agent-platform/. When the bootstrap runs cross-account, module.agent_iam
  # runs as THIS vend role; the ARNs resolve to the spoke account. The vend boundary
  # already allows iam:*/ssm:* on "*", so only the path-scoped statements are needed.
  agent_platform_role_arn   = "arn:${local.partition}:iam::${local.account_id}:role/eks-agent-platform/*"
  agent_platform_policy_arn = "arn:${local.partition}:iam::${local.account_id}:policy/eks-agent-platform/*"
  agent_platform_ssm_arn    = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/eks-agent-platform/*"

  tags = merge(var.tags, {
    Component = "fleet-vend"
    Team      = var.team
  })
}

################################################################################
# Permissions boundary — the maximum the vend role (and any role it creates for
# the cluster) can ever do. Allows the infra-provisioning surface broadly, then
# hard-denies the privilege-escalation vectors. The vend role carries it; its
# CreateRole is gated on it; so a compromised vend session can build clusters but
# can never mint IAM principals, touch org/account, or widen its own ceiling.
################################################################################

resource "aws_iam_policy" "vend_boundary" {
  name        = "${local.role_prefix}-vend-boundary"
  path        = local.iam_path
  description = "Permissions boundary ceiling for the eks-fleet vend role and the cluster roles it mints"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InfraProvisioningCeiling"
        Effect = "Allow"
        Action = [
          "eks:*",
          "ec2:*",
          "autoscaling:*",
          "elasticloadbalancing:*",
          "iam:*",
          "kms:*",
          "logs:*",
          "cloudwatch:*",
          # Karpenter interruption handling: EventBridge rules + an SQS queue.
          "events:*",
          "sqs:*",
          "ssm:*",
          "sts:AssumeRole",
          "sts:TagSession",
          "tag:GetResources",
        ]
        Resource = "*"
      },
      {
        # No vend session may ever create a human/long-lived principal, touch the
        # org or account, or strip a permissions boundary off a role.
        Sid    = "DenyEscalation"
        Effect = "Deny"
        Action = [
          "organizations:*",
          "account:*",
          "iam:CreateUser",
          "iam:CreateLoginProfile",
          "iam:CreateAccessKey",
          "iam:UpdateAccessKey",
          "iam:PutUserPermissionsBoundary",
          "iam:DeleteUserPermissionsBoundary",
          "iam:DeleteRolePermissionsBoundary",
        ]
        Resource = "*"
      },
      {
        # The vend role may not rewrite the boundary policy itself, nor alter its
        # own role — it cannot widen its own ceiling.
        Sid    = "ProtectBoundaryAndSelf"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:DeletePolicy",
          "iam:DeleteRole",
          "iam:PutRolePolicy",
          "iam:AttachRolePolicy",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = [
          "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}${local.role_prefix}-vend-boundary",
          local.vend_role_arn,
        ]
      },
    ]
  })

  tags = local.tags
}

################################################################################
# The vend role — trusted ONLY by the management hub role, with an ExternalId
# (confused-deputy guard). Carries the boundary above. The cluster-stack
# entrypoint runs as this role for a cross-account vend.
################################################################################

data "aws_iam_policy_document" "vend_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = [var.hub_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

resource "aws_iam_role" "vend" {
  name                 = local.vend_role_name
  path                 = local.iam_path
  assume_role_policy   = data.aws_iam_policy_document.vend_trust.json
  permissions_boundary = aws_iam_policy.vend_boundary.arn
  description          = "Cross-account role the eks-fleet hub assumes to provision EKS in this account"
  tags                 = local.tags
}

resource "aws_iam_role_policy" "vend" {
  name = "vend"
  role = aws_iam_role.vend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ProvisionInfra"
        Effect = "Allow"
        Action = [
          "eks:*",
          "ec2:*",
          "autoscaling:*",
          "elasticloadbalancing:*",
          "kms:*",
          "logs:*",
          "cloudwatch:*",
          # Karpenter interruption handling: EventBridge rules + an SQS queue.
          "events:*",
          "sqs:*",
          "tag:GetResources",
        ]
        Resource = "*"
      },
      {
        Sid    = "SSMState"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:PutParameter",
          "ssm:DeleteParameter",
          "ssm:AddTagsToResource",
        ]
        Resource = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/eks-fleet/*"
      },
      {
        # Read AWS's public service parameters — the cluster module resolves the
        # latest Bottlerocket/EKS AMI from /aws/service/* (AWS-owned, empty account).
        Sid      = "SSMPublicServiceRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:${local.partition}:ssm:${var.region}::parameter/aws/service/*"
      },
      {
        Sid    = "OIDCProvider"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:AddClientIDToOpenIDConnectProvider",
        ]
        Resource = "*"
      },
      {
        Sid      = "PassClusterRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = local.managed_role_arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "eks.amazonaws.com",
              "ec2.amazonaws.com",
              # Karpenter's controller role is an EKS Pod Identity role; creating
              # its pod-identity association passes the role to this service.
              "pods.eks.amazonaws.com",
            ]
          }
        }
      },
      {
        Sid    = "ReadClusterRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:GetInstanceProfile",
        ]
        # + the vend role's OWN arn: the cluster module's
        # enable_cluster_creator_admin_permissions resolves the creator via
        # aws_iam_session_context, which calls iam:GetRole on this assumed role.
        Resource = [local.managed_role_arn, local.managed_role_name_arn, local.managed_instance_prof_arn, local.vend_role_arn]
      },
      {
        # EKS managed node groups validate the eks-nodegroup service-linked role
        # AS THE CALLER — CreateNodegroup does iam:GetRole on
        # AWSServiceRoleForAmazonEKSNodegroup. GetRole takes no iam:AWSServiceName
        # context, so it lives in its own statement scoped to the SLR path.
        Sid      = "ReadServiceLinkedRoles"
        Effect   = "Allow"
        Action   = ["iam:GetRole"]
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"
      },
      {
        # On the first node group in an account EKS mints the SLR if it's absent.
        # Condition-locked to the EKS service principals — it can only create
        # AWS-owned service roles, never a real one (no escalation).
        Sid      = "CreateEKSServiceLinkedRoles"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = [
              "eks.amazonaws.com",
              "eks-nodegroup.amazonaws.com",
              "eks-fargate.amazonaws.com",
            ]
          }
        }
      },
      {
        # Create + modify cluster roles created under the /eks-fleet/ path. The
        # vend role's OWN permissions boundary (below) is the escalation ceiling —
        # it already denies minting users, touching org/account, and widening
        # itself — so a per-created-role boundary condition here is redundant
        # belt-and-suspenders. Path-scoping is the gate; the cluster component just
        # sets cluster_iam_role_path = /eks-fleet/ (no per-role boundary needed).
        Sid    = "ManageClusterRolesByPath"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = local.managed_role_arn
      },
      {
        Sid    = "DeleteClusterRoles"
        Effect = "Allow"
        Action = [
          "iam:DeleteRole",
          "iam:CreateInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:TagInstanceProfile",
        ]
        Resource = [local.managed_role_arn, local.managed_instance_prof_arn]
      },
      {
        # Detach + delete instance profiles at teardown. Karpenter's node
        # instance profile lives at the root path (<cluster>_<hash>), so these
        # two destructive actions also cover the env-prefixed root-path profiles
        # — without it `tofu destroy` 403s removing the node role from its
        # profile once Karpenter is already uninstalled (issue #84).
        Sid    = "DetachAndDeleteInstanceProfiles"
        Effect = "Allow"
        Action = [
          "iam:DeleteInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
        ]
        Resource = [local.managed_instance_prof_arn, local.managed_karpenter_instance_prof_arn]
      },
      {
        Sid    = "ManageClusterPolicies"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagPolicy",
        ]
        Resource = local.managed_policy_arn
      },
      {
        # agent-iam (eks-agent-platform): create + manage the operator IRSA role
        # under /eks-agent-platform/ during a vend. Path-scoped — the vend boundary
        # is the escalation ceiling, same gate model as ManageClusterRolesByPath.
        # The operator role carries no permissions_boundary, so no boundary
        # condition. Keep in sync with fleet-hub's ManageAgentPlatform* statements.
        Sid    = "ManageAgentPlatformRolesByPath"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:GetRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRoleDescription",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          # the AWS provider lists a role's instance profiles before DeleteRole
          # (to detach first) — required to tear an agent-platform role down.
          "iam:ListInstanceProfilesForRole",
          "iam:DeleteRole",
        ]
        Resource = local.agent_platform_role_arn
      },
      {
        # agent-iam: the tenant-boundary + tenant-baseline managed policies under
        # /eks-agent-platform/ — the agent-platform sibling of ManageClusterPolicies.
        # Keep in sync with fleet-hub.
        Sid    = "ManageAgentPlatformPolicies"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
          "iam:ListPolicyTags",
          "iam:DeletePolicy",
        ]
        Resource = local.agent_platform_policy_arn
      },
      {
        # agent-iam: the operator-startup SSM params under
        # /eks-agent-platform/<env>/agent-iam/* — the agent-platform sibling of
        # SSMState. Keep in sync with fleet-hub.
        Sid    = "AgentPlatformSSMState"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:DeleteParameter",
          "ssm:AddTagsToResource",
          "ssm:RemoveTagsFromResource",
          "ssm:ListTagsForResource",
        ]
        Resource = local.agent_platform_ssm_arn
      },
      {
        # agent-iam: tofu refreshes each aws_ssm_parameter via ssm:DescribeParameters
        # (a metadata read on plan/observe). DescribeParameters is a list action that
        # does NOT support resource-level permissions, so it must be granted on "*"
        # — it enumerates parameter metadata account-wide; value read/write stays
        # path-scoped by AgentPlatformSSMState above. Keep in sync with fleet-hub.
        Sid      = "AgentPlatformSSMDescribe"
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "*"
      },
    ]
  })
}

################################################################################
# SSM parameters — the hub/portal discover the vend role + its boundary from the
# workload account (/eks-fleet/<env>/fleet-vend/*).
################################################################################

resource "aws_ssm_parameter" "vend_role_arn" {
  name  = "${local.ssm_prefix}/vend_role_arn"
  type  = "String"
  value = aws_iam_role.vend.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "vend_permissions_boundary_arn" {
  name  = "${local.ssm_prefix}/vend_permissions_boundary_arn"
  type  = "String"
  value = aws_iam_policy.vend_boundary.arn
  tags  = local.tags
}
