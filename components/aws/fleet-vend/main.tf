################################################################################
# fleet-vend — the cross-account role the eks-fleet hub assumes to provision an
# EKS cluster in THIS workload account.
#
# The management-account Crossplane role (eks-fleet-crossplane) sts:AssumeRoles
# this role; the cluster-stack entrypoint then runs as it to stand up the
# network + cluster. Mirrors components/aws/agent-iam one layer up: a permissions
# boundary is the hard ceiling (capping the vend role itself AND every role it
# mints for the cluster), the identity policy may only create/modify roles under
# /eks-fleet/ that carry that boundary (the escalation guard), and the role ARN
# is published to SSM for the hub/portal to discover.
#
# NOTE: for the CreateRole-gated-on-boundary guard to hold at apply, the
# cluster-stack entrypoint must create the cluster's IAM roles under iam_role_path
# "/eks-fleet/" with this boundary attached (terraform-aws-eks
# iam_role_path / iam_role_permissions_boundary). That wiring lands with the first
# cross-account apply (rung 2) — this component defines the account-side contract.
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
        Resource = [local.managed_role_arn, local.managed_role_name_arn, local.managed_instance_prof_arn]
      },
      {
        # Create + modify cluster roles ONLY when they carry the boundary — the
        # privilege-escalation guard, copied from agent-iam one layer up.
        Sid    = "ManageClusterRolesWithBoundary"
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
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = aws_iam_policy.vend_boundary.arn
          }
        }
      },
      {
        Sid    = "DeleteClusterRoles"
        Effect = "Allow"
        Action = [
          "iam:DeleteRole",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile",
        ]
        Resource = [local.managed_role_arn, local.managed_instance_prof_arn]
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
