################################################################################
# fleet-unwedge — the cross-account break-glass role portal assumes to tear down
# a WEDGED vend's orphaned resources in THIS workload account.
#
# When a vend wedges (provider-opentofu's external-create-pending blocks both
# create and delete), the normal deprovision cascade can't complete and the
# half-built cluster's AWS resources are stranded. This role is the bounded
# teardown credential portal's owner-only force-unwedge action assumes to delete
# them.
#
# Deliberately distinct from fleet-vend:
#   - Trusted by PORTAL's management-account role, not the hub crossplane role —
#     vending stays the hub's, tearing down a wedge is portal's, and the vend
#     role's trust never has to widen.
#   - DELETE-ONLY. It can never create or modify a resource, so "portal assumed
#     the unwedge role" is unambiguously a teardown in CloudTrail.
#
# Scoping: the cluster-stack provider sets default_tags incl. ProvisionedBy =
# "eks-fleet" on every resource, so destructive actions are tag-conditioned to
# fleet-provisioned resources only — a resource without that tag is denied (a
# stuck teardown, never a wider blast radius). The condition-key support of every
# destructive action was verified against the AWS service-authorization
# reference; the handful that can't be tag-scoped (optional resource types, KMS
# aliases, IAM, OIDC providers) are scoped by typed-ARN / path / name instead and
# capped by the role's permissions boundary. See the per-statement notes.
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  role_prefix = "${var.environment}-eks-fleet"
  iam_path    = "/eks-fleet/"
  ssm_prefix  = "/eks-fleet/${var.environment}/fleet-unwedge"

  unwedge_role_name = "${local.role_prefix}-unwedge"
  unwedge_role_arn  = "arn:${local.partition}:iam::${local.account_id}:role${local.iam_path}${local.unwedge_role_name}"

  # Cluster IAM lives under the /eks-fleet/ path (the same gate fleet-vend mints
  # them under) — the path is the boundary for IAM, which doesn't tag-condition
  # delete/detach reliably.
  managed_role_arn          = "arn:${local.partition}:iam::${local.account_id}:role${local.iam_path}*"
  managed_policy_arn        = "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}*"
  managed_instance_prof_arn = "arn:${local.partition}:iam::${local.account_id}:instance-profile${local.iam_path}*"

  tags = merge(var.tags, {
    Component = "fleet-unwedge"
    Team      = var.team
  })
}

################################################################################
# Permissions boundary — the escalation ceiling for the unwedge role. Mirrors the
# fleet-vend boundary: a compromised unwedge session can tear down infra but can
# never mint principals, touch org/account, strip a boundary, or widen itself.
################################################################################

resource "aws_iam_policy" "unwedge_boundary" {
  name        = "${local.role_prefix}-unwedge-boundary"
  path        = local.iam_path
  description = "Permissions boundary ceiling for the eks-fleet break-glass unwedge role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TeardownCeiling"
        Effect = "Allow"
        Action = [
          "eks:*",
          "ec2:*",
          "autoscaling:*",
          "elasticloadbalancing:*",
          "iam:*",
          "kms:*",
          "logs:*",
          "events:*",
          "sqs:*",
          "tag:GetResources",
          "sts:GetCallerIdentity",
        ]
        Resource = "*"
      },
      {
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
        # The unwedge role may not alter its own boundary or itself — it cannot
        # widen its own ceiling.
        Sid    = "ProtectBoundaryAndSelf"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:DeletePolicy",
          "iam:DeleteRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = [
          "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}${local.role_prefix}-unwedge-boundary",
          local.unwedge_role_arn,
        ]
      },
    ]
  })

  tags = local.tags
}

################################################################################
# The unwedge role — trusted ONLY by portal's management-account role, with an
# ExternalId (confused-deputy guard). Carries the boundary above.
################################################################################

data "aws_iam_policy_document" "unwedge_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = [var.portal_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

resource "aws_iam_role" "unwedge" {
  name                 = local.unwedge_role_name
  path                 = local.iam_path
  assume_role_policy   = data.aws_iam_policy_document.unwedge_trust.json
  permissions_boundary = aws_iam_policy.unwedge_boundary.arn
  description          = "Cross-account break-glass role portal assumes to tear down a wedged eks-fleet vend in this account"
  tags                 = local.tags
}

resource "aws_iam_role_policy" "unwedge" {
  name = "unwedge"
  role = aws_iam_role.unwedge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Discovery — read-only, broad. tag:GetResources is the canonical
        # find-everything-with-ProvisionedBy=eks-fleet query the teardown drives.
        Sid    = "Discover"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "eks:List*",
          "eks:Describe*",
          "autoscaling:Describe*",
          "elasticloadbalancing:Describe*",
          "sqs:ListQueues",
          "sqs:GetQueueAttributes",
          "sqs:ListQueueTags",
          "events:ListRules",
          "events:ListTargetsByRule",
          "events:ListTagsForResource",
          "logs:DescribeLogGroups",
          "logs:ListTagsForResource",
          "kms:ListKeys",
          "kms:ListAliases",
          "kms:DescribeKey",
          "kms:ListResourceTags",
          "iam:ListOpenIDConnectProviders",
          "tag:GetResources",
        ]
        Resource = "*"
      },
      {
        # Destructive on fleet-provisioned resources ONLY. Every action here has a
        # REQUIRED resource type, so Resource:"*" still forces aws:ResourceTag to
        # be evaluated against the target — an untagged resource is denied. (Each
        # EKS child is tagged independently by the cluster-stack's default_tags;
        # there is no inheritance from the cluster.)
        Sid    = "TeardownTagged"
        Effect = "Allow"
        Action = [
          "ec2:DeleteSecurityGroup",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:DeleteSubnet",
          "ec2:DeleteVpc",
          "ec2:DeleteNatGateway",
          "ec2:DeleteInternetGateway",
          "ec2:DetachInternetGateway",
          "ec2:DeleteRouteTable",
          "ec2:DeleteRoute",
          "ec2:DeleteVpcEndpoints",
          "ec2:DeleteLaunchTemplate",
          "ec2:DeleteNetworkAcl",
          "ec2:DeleteEgressOnlyInternetGateway",
          "ec2:DeleteNetworkInterface",
          "ec2:DeleteFlowLogs",
          "eks:DeleteCluster",
          "eks:DeleteNodegroup",
          "eks:DeleteAddon",
          "eks:DeleteFargateProfile",
          "eks:DeletePodIdentityAssociation",
          "eks:DeleteAccessEntry",
          "eks:DisassociateIdentityProviderConfig",
          "logs:DeleteLogGroup",
          "kms:ScheduleKeyDeletion",
          "kms:DisableKey",
          "sqs:DeleteQueue",
          "autoscaling:DeleteAutoScalingGroup",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteTargetGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/ProvisionedBy" = "eks-fleet" }
        }
      },
      {
        # Elastic IPs are an OPTIONAL resource type for these actions — Resource:"*"
        # would bypass the tag gate, so the Resource is pinned to the typed ARN to
        # force tag evaluation.
        Sid      = "TeardownTaggedElasticIP"
        Effect   = "Allow"
        Action   = ["ec2:ReleaseAddress", "ec2:DisassociateAddress"]
        Resource = "arn:${local.partition}:ec2:${var.region}:${local.account_id}:elastic-ip/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/ProvisionedBy" = "eks-fleet" }
        }
      },
      {
        # EventBridge rules (Karpenter interruption) — same optional-type story:
        # pin the Resource to the rule ARN so the tag gate engages.
        Sid      = "TeardownTaggedEventRules"
        Effect   = "Allow"
        Action   = ["events:DeleteRule", "events:RemoveTargets"]
        Resource = "arn:${local.partition}:events:${var.region}:${local.account_id}:rule/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/ProvisionedBy" = "eks-fleet" }
        }
      },
      {
        # KMS aliases are untaggable, so they can't be tag-scoped — bound them to
        # the eks-fleet alias-name prefix. The key itself is tag-scoped above
        # (ScheduleKeyDeletion); this only removes the dangling alias pointer.
        Sid      = "TeardownKmsAlias"
        Effect   = "Allow"
        Action   = ["kms:DeleteAlias"]
        Resource = "arn:${local.partition}:kms:${var.region}:${local.account_id}:alias/eks-fleet*"
      },
      {
        # Cluster IAM — path-scoped to /eks-fleet/, the same gate fleet-vend mints
        # these under. IAM delete/detach don't tag-condition reliably; the path is
        # the boundary. Reads + deletes on the cluster's roles + instance profiles.
        Sid    = "TeardownClusterIAM"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:GetInstanceProfile",
          "iam:ListInstanceProfilesForRole",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:DeleteInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
        ]
        Resource = [local.managed_role_arn, local.managed_instance_prof_arn]
      },
      {
        Sid    = "TeardownClusterPolicies"
        Effect = "Allow"
        Action = [
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
        ]
        Resource = local.managed_policy_arn
      },
      {
        # OIDC providers carry no IAM path and don't tag-scope reliably, so they
        # fall to oidc-provider/* — capped by the escalation boundary. An account's
        # OIDC-provider set is small and fleet-owned, so the residual is bounded.
        Sid    = "TeardownOIDCProvider"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
        ]
        Resource = "arn:${local.partition}:iam::${local.account_id}:oidc-provider/*"
      },
    ]
  })
}

################################################################################
# SSM — publish the unwedge role ARN so the hub/portal can discover it (parity
# with fleet-vend; portal also derives it from the convention).
################################################################################

resource "aws_ssm_parameter" "unwedge_role_arn" {
  name  = "${local.ssm_prefix}/unwedge_role_arn"
  type  = "String"
  value = aws_iam_role.unwedge.arn
  tags  = local.tags
}
