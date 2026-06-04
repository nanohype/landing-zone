################################################################################
# fleet-hub — the management-account side of the eks-fleet cluster factory.
#
# Provisions: the eks-fleet-crossplane IRSA role the hub's Crossplane runner
# (provider-opentofu) assumes, and the S3 bucket holding the vended clusters'
# OpenTofu state. The role can (a) provision a cluster in THIS account directly
# (same-account vend, where the Cluster's vendRoleArn is empty), (b) sts:AssumeRole
# a fleet-vend role in any workload account (cross-account vend), and (c) read/write
# the fleet state bucket. A permissions boundary caps it the same way fleet-vend is
# capped — it can build clusters but never mint principals, touch org/account, or
# widen its own ceiling.
#
# Applied AFTER the management EKS cluster exists (it takes that cluster's OIDC
# provider as input). The role name is fixed (eks-fleet-crossplane, root path) to
# match the eks-fleet bootstrap ServiceAccount annotation. The CreateRole gate is
# PATH-SCOPED to /eks-fleet/ (like fleet-vend): the hub role's own boundary is the
# escalation ceiling, so every cluster it vends just needs its roles under
# /eks-fleet/ (the composition sets cluster_iam_role_path = /eks-fleet/ for hub vends).
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  role_name    = "eks-fleet-crossplane"
  iam_path     = "/eks-fleet/"
  sa_subject   = "system:serviceaccount:crossplane-system:provider-opentofu"
  ssm_prefix   = "/eks-fleet/${var.environment}/fleet-hub"
  hub_role_arn = "arn:${local.partition}:iam::${local.account_id}:role/${local.role_name}"

  # Cross-account vend roles the hub may assume (any account, any env), and the
  # same-account cluster roles/policies/profiles it may manage — only under the
  # eks-fleet path.
  vend_role_arn_pattern     = "arn:${local.partition}:iam::*:role/eks-fleet/*-eks-fleet-vend"
  managed_role_arn          = "arn:${local.partition}:iam::${local.account_id}:role${local.iam_path}*"
  managed_role_name_arn     = "arn:${local.partition}:iam::${local.account_id}:role/${var.environment}-eks-fleet-*"
  managed_policy_arn        = "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}*"
  managed_instance_prof_arn = "arn:${local.partition}:iam::${local.account_id}:instance-profile${local.iam_path}*"

  state_bucket_arn = "arn:${local.partition}:s3:::${var.state_bucket_name}"

  tags = merge(var.tags, {
    Component = "fleet-hub"
    Team      = var.team
  })
}

################################################################################
# Fleet state bucket — provider-opentofu writes each vended cluster's tofu state
# here (per-cluster key via the Workspace initArgs). Versioned + encrypted +
# private; S3 native locking (use_lockfile), no DynamoDB table.
################################################################################

resource "aws_s3_bucket" "fleet_state" {
  bucket = var.state_bucket_name
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "fleet_state" {
  bucket = aws_s3_bucket.fleet_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fleet_state" {
  bucket = aws_s3_bucket.fleet_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "fleet_state" {
  bucket                  = aws_s3_bucket.fleet_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################################################################################
# Permissions boundary — the ceiling for the hub role. Allows the provisioning +
# assume + state surface broadly, then hard-denies the escalation vectors. The
# hub role carries it and its CreateRole is gated on it.
################################################################################

resource "aws_iam_policy" "hub_boundary" {
  name        = "eks-fleet-hub-boundary"
  path        = local.iam_path
  description = "Permissions boundary ceiling for the eks-fleet-crossplane hub role and the cluster roles it mints"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "HubCeiling"
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
          "s3:*",
          "sts:AssumeRole",
          "sts:TagSession",
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
          "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}eks-fleet-hub-boundary",
          local.hub_role_arn,
        ]
      },
    ]
  })

  tags = local.tags
}

################################################################################
# The hub role — assumed by the hub's provider-opentofu pod via IRSA
# (OIDC web identity, SA crossplane-system/provider-opentofu). Carries the
# boundary. Name + root path are fixed to match the bootstrap SA annotation.
################################################################################

data "aws_iam_policy_document" "hub_trust" {
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
      values   = [local.sa_subject]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hub" {
  name                 = local.role_name
  assume_role_policy   = data.aws_iam_policy_document.hub_trust.json
  permissions_boundary = aws_iam_policy.hub_boundary.arn
  description          = "IRSA role the eks-fleet Crossplane runner assumes to vend clusters (same- and cross-account)"
  tags                 = local.tags
}

resource "aws_iam_role_policy" "hub" {
  name = "hub"
  role = aws_iam_role.hub.id

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
        # Cross-account vend: assume a fleet-vend role in any workload account.
        Sid      = "AssumeVendRoles"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = local.vend_role_arn_pattern
      },
      {
        # The fleet state bucket — provider-opentofu's S3 backend (object rw +
        # list + the S3 native lock object).
        Sid    = "FleetState"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketVersioning",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
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
        # + the hub role's OWN arn: the cluster module's
        # enable_cluster_creator_admin_permissions resolves the creator via
        # aws_iam_session_context, which calls iam:GetRole on this assumed role.
        Resource = [local.managed_role_arn, local.managed_role_name_arn, local.managed_instance_prof_arn, local.hub_role_arn]
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
        # Same-account cluster-role management, path-scoped to /eks-fleet/. The hub
        # role's OWN boundary (hub_boundary) is the escalation ceiling, so a
        # per-created-role boundary condition is redundant — path-scoping is the
        # gate (mirrors the relaxed fleet-vend gate). The provider-opentofu runner
        # on the hub provisions same-account clusters AS this role, so their IAM
        # roles must land under /eks-fleet/ (the composition sets cluster_iam_role_path).
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
# SSM parameters — the bootstrap/portal discover the hub role + state bucket
# (/eks-fleet/<env>/fleet-hub/*).
################################################################################

resource "aws_ssm_parameter" "hub_role_arn" {
  name  = "${local.ssm_prefix}/hub_role_arn"
  type  = "String"
  value = aws_iam_role.hub.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "state_bucket" {
  name  = "${local.ssm_prefix}/state_bucket"
  type  = "String"
  value = aws_s3_bucket.fleet_state.bucket
  tags  = local.tags
}
