################################################################################
# portal-spoke — the per-account role the portal worker assumes (from the hub) to
# reach THIS workload account's EKS clusters.
#
# portal mints EKS bearer tokens for the clusters it manages and reads their
# control-plane status (eks:DescribeCluster); both run as this role. It is trusted
# ONLY by the portal hub worker role, with an ExternalId (confused-deputy guard),
# and is least-privilege: read-only EKS describe/list + the sts:GetCallerIdentity
# the connection-test uses. A permissions boundary caps the ceiling at that read
# surface. The role ARN is published to SSM; the ExternalId is a tofu output (not a
# secret). Both are set as the Account's AssumeRoleARN / ExternalID in portal.
#
# CONTRACT: eks:DescribeCluster is the AWS control-plane API — it needs only this
# IAM grant, no kube access entry. The EKS-TOKEN path (kube API auth) additionally
# needs this role granted a read access entry on each managed cluster; the
# cluster-stack adds it when portal_access_role_arn is set.
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  role_prefix = "${var.environment}-portal"
  iam_path    = "/portal/"
  ssm_prefix  = "/portal/${var.environment}/portal-spoke"

  spoke_role_name = "${local.role_prefix}-spoke"
  cluster_arn     = "arn:${local.partition}:eks:*:${local.account_id}:cluster/*"

  tags = merge(var.tags, {
    Component = "portal-spoke"
    Team      = var.team
  })
}

################################################################################
# Permissions boundary — the ceiling for the spoke role. The role's own policy is
# already read-only, so the boundary is defense in depth: it caps the ceiling at
# that read surface and hard-denies every escalation vector (no IAM, no org, no
# account). A read-only role can't widen itself, but the deny makes that explicit.
################################################################################

resource "aws_iam_policy" "spoke_boundary" {
  name        = "${local.role_prefix}-spoke-boundary"
  path        = local.iam_path
  description = "Permissions boundary ceiling for the portal cross-account spoke role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadCeiling"
        Effect = "Allow"
        Action = [
          "eks:Describe*",
          "eks:List*",
          "sts:GetCallerIdentity",
          "tag:GetResources",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyEscalation"
        Effect = "Deny"
        Action = [
          "organizations:*",
          "account:*",
          "iam:*",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.tags
}

################################################################################
# The spoke role — trusted ONLY by the portal hub worker role, with an ExternalId.
################################################################################

data "aws_iam_policy_document" "spoke_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.portal_hub_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

resource "aws_iam_role" "spoke" {
  name                 = local.spoke_role_name
  path                 = local.iam_path
  assume_role_policy   = data.aws_iam_policy_document.spoke_trust.json
  permissions_boundary = aws_iam_policy.spoke_boundary.arn
  description          = "Cross-account role the portal worker assumes to read this account's EKS clusters"
  tags                 = local.tags
}

resource "aws_iam_role_policy" "spoke" {
  name = "spoke"
  role = aws_iam_role.spoke.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The control-plane read the cluster-health watcher surfaces (status +
        # platform version). DescribeCluster is the AWS API — it needs this IAM
        # grant, not a kube access entry. Scoped to this account's clusters.
        Sid      = "DescribeClusters"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = local.cluster_arn
      },
      {
        # ListClusters has no per-cluster resource (it enumerates the account).
        Sid      = "ListClusters"
        Effect   = "Allow"
        Action   = ["eks:ListClusters"]
        Resource = "*"
      },
      {
        # The connection-test verifies the assume worked via sts:GetCallerIdentity
        # (and the boundary above must allow it for the call to succeed).
        Sid      = "IdentityCheck"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]
  })
}

################################################################################
# SSM — the operator discovers the spoke role to register the Account in portal
# (/portal/<env>/portal-spoke/*). The ExternalId is a tofu output (not a secret).
################################################################################

resource "aws_ssm_parameter" "spoke_role_arn" {
  name  = "${local.ssm_prefix}/spoke_role_arn"
  type  = "String"
  value = aws_iam_role.spoke.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "spoke_permissions_boundary_arn" {
  name  = "${local.ssm_prefix}/spoke_permissions_boundary_arn"
  type  = "String"
  value = aws_iam_policy.spoke_boundary.arn
  tags  = local.tags
}
