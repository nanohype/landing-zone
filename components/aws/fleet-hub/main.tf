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
# match the eks-fleet bootstrap ServiceAccount annotation. The role-write gate is
# double-locked (like fleet-vend): PATH-SCOPED to /eks-fleet/, AND every role it
# creates or widens must carry the hub boundary (iam:PermissionsBoundary
# condition) — for same-account vends the composition sets
# cluster_iam_role_path = /eks-fleet/ and cluster_permissions_boundary_arn = the
# hub boundary ARN (published in SSM as hub_permissions_boundary_arn).
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  role_name  = "eks-fleet-crossplane"
  iam_path   = "/eks-fleet/"
  sa_subject = "system:serviceaccount:crossplane-system:provider-opentofu"

  # IAM OIDC condition keys are the issuer URL WITHOUT the scheme; the EKS module
  # (and aws eks describe-cluster) report it WITH https://. Strip it so the var is
  # tolerant of either form — a scheme in the key silently breaks every assume.
  oidc_issuer_host = replace(var.oidc_issuer, "https://", "")
  ssm_prefix       = "/eks-fleet/${var.environment}/fleet-hub"
  hub_role_arn     = "arn:${local.partition}:iam::${local.account_id}:role/${local.role_name}"

  hub_boundary_name = "eks-fleet-hub-boundary"
  hub_boundary_arn  = "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}${local.hub_boundary_name}"

  # agent-iam's tenant permissions boundary — created under /eks-agent-platform/
  # during a same-account vend and carried by every operator-minted tenant role.
  # Each cluster names it <cluster_name>-agent-platform-tenant-boundary, so this is
  # an env-scoped wildcard (matched with ArnNotLike below): the hub ceiling accepts
  # the tenant boundary of ANY cluster co-located in this environment, not just the
  # first one bootstrapped.
  tenant_boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/eks-agent-platform/${var.environment}-*-agent-platform-tenant-boundary"

  # Cross-account vend roles the hub may assume (any account, any env), and the
  # same-account cluster roles/policies/profiles it may manage — only under the
  # eks-fleet path.
  vend_role_arn_pattern     = "arn:${local.partition}:iam::*:role/eks-fleet/*-eks-fleet-vend"
  managed_role_arn          = "arn:${local.partition}:iam::${local.account_id}:role${local.iam_path}*"
  managed_role_name_arn     = "arn:${local.partition}:iam::${local.account_id}:role/${var.environment}-eks-fleet-*"
  managed_policy_arn        = "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}*"
  managed_instance_prof_arn = "arn:${local.partition}:iam::${local.account_id}:instance-profile${local.iam_path}*"

  # Karpenter (v1) mints its node instance profile at the ROOT path as
  # <cluster>_<hash>; the EKS cluster name is env-prefixed (see cluster-stack),
  # so every Karpenter profile in this account shares the ${var.environment}-
  # prefix. The hub role never creates these — but at teardown (after Karpenter
  # is uninstalled) it must detach + delete them to drop the node role, which
  # falls outside the /eks-fleet/ path.
  managed_karpenter_instance_prof_arn = "arn:${local.partition}:iam::${local.account_id}:instance-profile/${var.environment}-*"

  # agent-iam provisioning surface — the eks-agent-platform operator IRSA role, the
  # two tenant managed policies, and the operator-startup SSM params all land under
  # /eks-agent-platform/. The hub role provisions them in a same-account vend
  # (module.agent_iam runs as this role). The hub boundary already allows iam:*/
  # ssm:* on "*", so only the path-scoped inline statements below are needed.
  agent_platform_role_arn   = "arn:${local.partition}:iam::${local.account_id}:role/eks-agent-platform/*"
  agent_platform_policy_arn = "arn:${local.partition}:iam::${local.account_id}:policy/eks-agent-platform/*"
  agent_platform_ssm_arn    = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/eks-agent-platform/*"

  state_bucket_arn = "arn:${local.partition}:s3:::${var.state_bucket_name}"

  tags = merge(var.tags, {
    Component = "fleet-hub"
    Team      = var.team
  })
}

################################################################################
# Fleet state bucket — provider-opentofu writes each vended cluster's tofu state
# here (per-cluster key via the Workspace initArgs). This holds the OpenTofu
# state of every vended cluster: the highest-value data in the fleet's blast
# radius. Hardened accordingly — versioned, SSE-KMS with a dedicated CMK,
# in-transit TLS enforced by bucket policy, server access logs to a private
# sibling bucket, public access blocked; S3 native locking (use_lockfile).
################################################################################

resource "aws_kms_key" "fleet_state" {
  description             = "eks-fleet ${var.environment} tofu state bucket encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.tags

  # Crown-jewel: this CMK decrypts every vended cluster's tofu state. A tofu
  # destroy of fleet-hub must never schedule it for deletion (which would render
  # the state bucket unreadable) — deliberate teardown removes this guard first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "fleet_state" {
  name          = "alias/eks-fleet-${var.environment}-state"
  target_key_id = aws_kms_key.fleet_state.key_id
}

resource "aws_s3_bucket" "fleet_state" {
  bucket = var.state_bucket_name
  tags   = local.tags

  # Crown-jewel: this bucket holds every vended cluster's tofu state. A tofu
  # destroy of fleet-hub must never delete it — a deliberate teardown removes this
  # guard first. Guards against issue #660-class "destroy took the state with it".
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "fleet_state" {
  bucket = aws_s3_bucket.fleet_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Versioning keeps every prior state as a noncurrent object; without expiry they
# accumulate forever. Keep the 10 most recent noncurrent versions unconditionally
# (recent-rollback safety), and expire the rest after 90 days. Aborted multipart
# uploads (interrupted state writes) are swept after 7 days.
resource "aws_s3_bucket_lifecycle_configuration" "fleet_state" {
  bucket     = aws_s3_bucket.fleet_state.id
  depends_on = [aws_s3_bucket_versioning.fleet_state]

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fleet_state" {
  bucket = aws_s3_bucket.fleet_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.fleet_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "fleet_state" {
  bucket                  = aws_s3_bucket.fleet_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "fleet_state" {
  bucket = aws_s3_bucket.fleet_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.fleet_state.arn,
        "${aws_s3_bucket.fleet_state.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_logging" "fleet_state" {
  bucket        = aws_s3_bucket.fleet_state.id
  target_bucket = aws_s3_bucket.fleet_state_logs.id
  target_prefix = "state-access/"
}

# Access-log sink for the state bucket. Private, its own TLS deny, and grants
# only the S3 logging service principal PutObject for this source bucket.
resource "aws_s3_bucket" "fleet_state_logs" {
  bucket = "${var.state_bucket_name}-logs"
  tags   = local.tags

  lifecycle {
    precondition {
      condition     = length("${var.state_bucket_name}-logs") <= 63
      error_message = "log bucket ${var.state_bucket_name}-logs exceeds S3's 63-character limit; shorten state_bucket_name."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "fleet_state_logs" {
  bucket                  = aws_s3_bucket.fleet_state_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fleet_state_logs" {
  bucket = aws_s3_bucket.fleet_state_logs.id
  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 on the log target: S3 log delivery encrypts with the target
      # bucket's default key, and a CMK on a log sink adds a per-object kms cost
      # with no marginal benefit for access-log records.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "fleet_state_logs" {
  bucket = aws_s3_bucket.fleet_state_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3ServerAccessLogging"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.fleet_state_logs.arn}/*"
        Condition = {
          ArnLike      = { "aws:SourceArn" = aws_s3_bucket.fleet_state.arn }
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.fleet_state_logs.arn,
          "${aws_s3_bucket.fleet_state_logs.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

################################################################################
# Permissions boundary — the ceiling for the hub role. Allows the provisioning +
# assume + state surface broadly, then hard-denies the escalation vectors. The
# hub role carries it and its CreateRole is gated on it.
################################################################################

resource "aws_iam_policy" "hub_boundary" {
  name        = local.hub_boundary_name
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
          # This boundary is also the RUNTIME ceiling for every cluster role
          # minted with it (node, Karpenter controller, EBS CSI, operator): node
          # image pulls (ECR read), SSM Session Manager channels, EKS Pod
          # Identity handshakes, and Karpenter's pricing lookups live here even
          # though the hub role itself never calls them.
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ec2messages:*",
          "ssmmessages:*",
          "eks-auth:AssumeRoleForPodIdentity",
          "pricing:GetProducts",
        ]
        Resource = "*"
      },
      {
        # Ceiling-level twin of the identity policy's WithBoundary gates, so the
        # guarantee survives identity-policy tampering: any role write performed
        # under this boundary must target a role carrying an approved boundary —
        # this one (cluster infra roles, the agent-platform operator) or the
        # agent-platform tenant boundary (operator-minted tenant roles, which
        # that ceiling hard-caps: no iam, no sts:AssumeRole). A session capped by
        # this boundary can therefore never mint or widen an unbounded principal,
        # even transitively through a role it is allowed to write.
        Sid    = "DenyUnboundedRoleWrites"
        Effect = "Deny"
        Action = [
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:PutRolePolicy",
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = "*"
        Condition = {
          ArnNotLike = {
            "iam:PermissionsBoundary" = [
              local.hub_boundary_arn,
              local.tenant_boundary_arn,
            ]
          }
        }
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
          local.hub_boundary_arn,
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
      variable = "${local.oidc_issuer_host}:sub"
      values   = [local.sa_subject]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
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
        # Same-account cluster-role management: create + write cluster roles
        # under /eks-fleet/ ONLY when the target role carries the hub boundary —
        # the same condition-locked CreateRole gate agent-iam applies to tenant
        # roles (mirrors fleet-vend). Path-scoping picks WHICH roles; the
        # iam:PermissionsBoundary condition guarantees anything minted or widened
        # is capped by the hub's own ceiling, so a compromised hub session cannot
        # mint an unbounded admin role. The composition satisfies it by setting
        # cluster_permissions_boundary_arn to this boundary (published in SSM as
        # hub_permissions_boundary_arn).
        Sid    = "ManageClusterRolesWithBoundary"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = local.managed_role_arn
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = local.hub_boundary_arn
          }
        }
      },
      {
        # Role lifecycle actions whose request context carries no
        # iam:PermissionsBoundary key (so they cannot be boundary-conditioned) —
        # none of them can widen a role's effective permissions: the boundary set
        # at create time keeps the cap, and a trust-policy edit only changes who
        # may assume an already-capped role.
        Sid    = "ManageClusterRoleLifecycle"
        Effect = "Allow"
        Action = [
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
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
        # ManageClusterPolicies matches every policy under /eks-fleet/ —
        # including the hub boundary itself. Explicitly deny rewriting or
        # deleting the boundary so the ceiling the WithBoundary gates rely on
        # stays immutable to the hub session. The boundary's own
        # ProtectBoundaryAndSelf already denies this; this is the identity-layer
        # half, so the protection never hinges on a single mechanism.
        Sid    = "ProtectHubBoundary"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:DeletePolicy",
        ]
        Resource = local.hub_boundary_arn
      },
      {
        # agent-iam (eks-agent-platform): create + write the operator IRSA role
        # under /eks-agent-platform/ during a same-account vend — gated exactly
        # like ManageClusterRolesWithBoundary: the operator role must carry the
        # hub boundary (agent-iam's operator_permissions_boundary_arn input,
        # which the cluster-bootstrap entrypoint sets from the SSM-published
        # boundary ARN). Keep in sync with fleet-vend's ManageAgentPlatform*
        # statements.
        Sid    = "ManageAgentPlatformRolesWithBoundary"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
        ]
        Resource = local.agent_platform_role_arn
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = local.hub_boundary_arn
          }
        }
      },
      {
        # agent-iam: reads + the boundary-keyless lifecycle of the operator role
        # (no iam:PermissionsBoundary in these request contexts; none can widen
        # the role). Keep in sync with fleet-vend.
        Sid    = "ManageAgentPlatformRoleLifecycle"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRoleDescription",
          "iam:GetRolePolicy",
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
        # The tenant boundary stays hub-writable BY DESIGN: agent-iam owns its
        # content and rolls updates out through the vend path, so it cannot be
        # made immutable here the way the hub boundary is. Keep in sync with
        # fleet-vend.
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
        # SSMState. Keep in sync with fleet-vend.
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
        # path-scoped by AgentPlatformSSMState above. Keep in sync with fleet-vend.
        Sid      = "AgentPlatformSSMDescribe"
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "*"
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

# The composition wires this into cluster-stack's cluster_permissions_boundary_arn
# and cluster-bootstrap's operator_permissions_boundary_arn for same-account
# vends — the hub role's WithBoundary gates reject any role that doesn't carry it.
# Mirrors fleet-vend's vend_permissions_boundary_arn for cross-account vends.
resource "aws_ssm_parameter" "hub_permissions_boundary_arn" {
  name  = "${local.ssm_prefix}/hub_permissions_boundary_arn"
  type  = "String"
  value = aws_iam_policy.hub_boundary.arn
  tags  = local.tags
}
