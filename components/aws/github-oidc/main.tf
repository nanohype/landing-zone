locals {
  # Subject claims the deploy role trusts: the cartesian product of the configured
  # repos and the allowed claim suffixes (repo:<org>/<repo>:<claim>). The default
  # claim set is the four GitHub Environments the deploy/destroy/e2e workflows
  # declare, each an exact name (validated: no wildcard, no pull_request or ref:
  # claim, never environment:plan or environment:drift, which the PR plan job and
  # drift.yml declare and the read-only plan role trusts). Only Actions workflows
  # in these repos that declare
  # one of these environments may assume the role — from any ref, so each
  # environment's own deployment-branch policy is part of this control.
  subjects = flatten([
    for r in var.github_repos : [
      for c in var.allowed_subject_claims : "repo:${var.github_org}/${r}:${c}"
    ]
  ])

  tags = merge(var.tags, {
    Component = "github-oidc"
    Team      = var.team
  })
}

################################################################################
# GitHub Actions OIDC provider
#
# One provider per account for this issuer. If the account already has it
# (created out of band or by another stack), set create_oidc_provider = false
# to reference the existing one instead of conflicting on a second create.
################################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.oidc_thumbprints
  tags            = local.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

################################################################################
# Permissions boundary — the ceiling on the deploy and plan roles
#
# Created when create_permissions_boundary is set, and then attached to BOTH the
# deploy role and the plan role (as permissions_boundary_arn is when supplied
# instead). It grants nothing: the first statement allows everything, so the
# managed policies attached to each role (AdministratorAccess on a deploy role,
# ReadOnlyAccess on the plan role) stay the effective grant. What it adds is a
# set of denies that hold whatever is attached to the role, because an identity
# policy cannot widen past a boundary and an explicit deny beats any allow.
#
# One question decides what is on the list: what must a CI session, acting AS
# ITSELF, never be able to do in an account it administers? Four answers, one or
# two statements each:
#
#   1. Rewrite its own definition. The boundary policy, the roles a github-oidc
#      leaf creates (this leaf's deploy and plan roles by ARN, and any role tagged
#      Component = github-oidc, which covers the ECR Public pull role on its own
#      leaf in the same account) and the GitHub OIDC provider are changed by a
#      local apply with the account's own admin credentials, never by the
#      identities they define. Without this, one AttachRolePolicy or
#      UpdateAssumeRolePolicy turns a development deploy job into a wider trust,
#      and one CreatePolicyVersion turns this boundary into an allow-all.
#   2. Shed a ceiling. Delete{Role,User}PermissionsBoundary is refused on every
#      principal: no component removes a boundary, and stripping one is the
#      single call that uncaps a principal.
#   3. Step out into a principal this boundary does not cap. sts:AssumeRole is
#      refused (nothing the deploy, destroy, e2e or plan jobs run chains into a
#      role; the providers mint EKS tokens from the job's own identity), and so
#      is minting an IAM user, a console password or a long-lived key, which
#      would outlive the job's one-hour session.
#   4. Act beyond the account, or blind its audit. Organizations and account
#      settings (leave the org, close the account, change its contacts or
#      regions) are not CI business in a member account. The audit-service verbs
#      are exactly org-scp's DenyDisablingSecurity, which this repo authors but
#      ships unattached (docs/threat-model.md, section 6): this boundary holds
#      them for the most exposed admin principal in the account whether or not
#      that SCP is in force. No component in a workload account manages a trail,
#      a detector, a recorder, Security Hub or an analyzer, so no deploy needs
#      them.
#
# WHAT IT DOES NOT DO, and why. It does not require the roles the deploy session
# creates to carry this boundary (a Deny on CreateRole/PutRolePermissionsBoundary
# unless iam:PermissionsBoundary is this ARN, as fleet-vend's vend boundary
# does). The development tree creates roles in a dozen components (cluster and
# its EKS/Karpenter modules, cluster-addons, druid, pipeline, governance,
# managed-monitoring, backup, model-import, network's flow logs, agent-iam),
# most with no boundary input, and two more (break-glass, fleet-hub) put a
# boundary of their own on theirs, so that Deny would fail the first
# deploy.yml run on every role it touches. It would also be the wrong ceiling
# for them: these denies are written for a CI session, and the agent-platform
# operator, for one, assumes roles at runtime. So a role the session creates,
# and compute it hands that role to, runs outside this boundary. That residual is
# stated in docs/threat-model.md, section 1; closing it means threading a
# boundary through every role-creating component, as fleet-vend does for vended
# clusters.
################################################################################

data "aws_caller_identity" "current" {
  count = var.create_permissions_boundary ? 1 : 0
}

data "aws_partition" "current" {
  count = var.create_permissions_boundary ? 1 : 0
}

locals {
  boundary_partition = var.create_permissions_boundary ? data.aws_partition.current[0].partition : ""
  boundary_account   = var.create_permissions_boundary ? data.aws_caller_identity.current[0].account_id : ""

  # Built rather than read from aws_iam_policy.boundary, because the policy names
  # its own ARN (ProtectThisBoundary) and a resource cannot reference itself. The
  # roles use the same string, so a plan shows the exact boundary they will carry;
  # depends_on on each role orders the policy's creation first.
  created_boundary_arn = var.create_permissions_boundary ? "arn:${local.boundary_partition}:iam::${local.boundary_account}:policy/${var.permissions_boundary_name}" : null

  # What the deploy and plan roles carry: the boundary this component creates, the
  # one supplied in permissions_boundary_arn (the two are mutually exclusive), or
  # none.
  permissions_boundary_arn = var.create_permissions_boundary ? local.created_boundary_arn : (var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null)

  # The roles this leaf creates, by ARN. The tag-keyed statement below also
  # covers them; naming them as well keeps them protected on a role that predates
  # the Component tag.
  protected_role_arns = var.create_permissions_boundary ? concat(
    var.create_deploy_role ? ["arn:${local.boundary_partition}:iam::${local.boundary_account}:role/${var.role_name}"] : [],
    var.create_plan_role ? ["arn:${local.boundary_partition}:iam::${local.boundary_account}:role/${var.plan_role_name}"] : [],
  ) : []

  # Every write that changes what a role is: its trust, its policies, its
  # boundary, its tags (the tag statement keys on Component), or its existence.
  role_definition_actions = [
    "iam:DeleteRole",
    "iam:UpdateRole",
    "iam:UpdateRoleDescription",
    "iam:UpdateAssumeRolePolicy",
    "iam:AttachRolePolicy",
    "iam:DetachRolePolicy",
    "iam:PutRolePolicy",
    "iam:DeleteRolePolicy",
    "iam:PutRolePermissionsBoundary",
    "iam:DeleteRolePermissionsBoundary",
    "iam:TagRole",
    "iam:UntagRole",
  ]
}

data "aws_iam_policy_document" "boundary" {
  count = var.create_permissions_boundary ? 1 : 0

  statement {
    sid       = "AllowWhatTheIdentityPolicyGrants"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  # 1. Its own definition: this policy, ...
  statement {
    sid    = "ProtectThisBoundary"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [local.created_boundary_arn]
  }

  # ... the roles this leaf creates, ...
  statement {
    sid       = "ProtectTheseCiRoles"
    effect    = "Deny"
    actions   = local.role_definition_actions
    resources = local.protected_role_arns
  }

  # ... every role any github-oidc leaf creates (the ECR Public pull role trusts
  # pull_request, so a deploy session attaching a policy to it would hand that
  # policy to every same-repository pull request), ...
  statement {
    sid       = "ProtectEveryGithubOidcRole"
    effect    = "Deny"
    actions   = local.role_definition_actions
    resources = ["arn:${local.boundary_partition}:iam::${local.boundary_account}:role/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Component"
      values   = ["github-oidc"]
    }
  }

  # ... and the identity provider every one of those trusts names.
  statement {
    sid    = "ProtectTheGithubOidcProvider"
    effect = "Deny"
    actions = [
      "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
    ]
    resources = [local.oidc_provider_arn]
  }

  # 2. Shedding a ceiling, from any principal.
  statement {
    sid    = "DenyStrippingABoundary"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
    ]
    resources = ["*"]
  }

  # 3. Stepping out into a principal this boundary does not cap.
  statement {
    sid    = "DenyLeavingThisBoundary"
    effect = "Deny"
    actions = [
      "sts:AssumeRole",
      "iam:CreateUser",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:CreateAccessKey",
      "iam:CreateServiceSpecificCredential",
    ]
    resources = ["*"]
  }

  # 4. Beyond the account, and its audit.
  statement {
    sid    = "DenyOrganizationAndAccountActions"
    effect = "Deny"
    actions = [
      "organizations:*",
      "account:*",
    ]
    resources = ["*"]
  }

  statement {
    # The verbs of org-scp's DenyDisablingSecurity, held here for this one
    # principal whether or not that SCP is attached.
    sid    = "DenyDisablingSecurityServices"
    effect = "Deny"
    actions = [
      "cloudtrail:DeleteTrail",
      "cloudtrail:StopLogging",
      "cloudtrail:UpdateTrail",
      "guardduty:DeleteDetector",
      "guardduty:DisassociateFromMasterAccount",
      "guardduty:UpdateDetector",
      "config:DeleteConfigurationRecorder",
      "config:DeleteDeliveryChannel",
      "config:StopConfigurationRecorder",
      "securityhub:DisableSecurityHub",
      "securityhub:DeleteMembers",
      "securityhub:DisassociateFromMasterAccount",
      "access-analyzer:DeleteAnalyzer",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "boundary" {
  count       = var.create_permissions_boundary ? 1 : 0
  name        = var.permissions_boundary_name
  description = "Permissions boundary on the GitHub Actions deploy and plan roles: allows what their policies grant, denies self-modification, boundary removal, role assumption, IAM users and keys, Organizations/account actions and disabling audit services"
  policy      = data.aws_iam_policy_document.boundary[0].json
  tags        = local.tags
}

################################################################################
# Deploy role — assumed by GitHub Actions to provision/destroy the substrate
#
# Trust is scoped to workflows in the configured repos ONLY (the load-bearing
# control). The role ships with NO permissions — attach the managed policies CI
# needs via managed_policy_arns. Inert until you do, which is the safe default
# for a role that isn't used by default. AdministratorAccess is refused without a
# boundary (create_permissions_boundary, or permissions_boundary_arn): the
# workload-development leaf attaches it under the boundary above.
#
# NOTE: the org currently runs `deploy` and the e2e as LOCAL execs with SSO
# credentials — neither assumes this role. It exists for the OPTIONAL GitHub
# Actions CI path; its ARN goes in the DEPLOY_ROLE_ARN secret on the GitHub
# Environment deploy.yml/destroy.yml declare, and in the E2E_AWS_ROLE_ARN secret
# on `e2e` for e2e.yml — never in AWS_ROLE_ARN, the secret on the `plan`
# environment that holds plan_role_arn for ci.yml's plan job, or in
# DRIFT_PLAN_ROLE_ARNS, the secret on the `drift` GitHub Environment that maps
# each account directory to that account's plan_role_arn for drift.yml.
################################################################################

data "aws_iam_policy_document" "trust" {
  count = var.create_deploy_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "deploy" {
  count                = var.create_deploy_role ? 1 : 0
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust[0].json
  permissions_boundary = local.permissions_boundary_arn
  max_session_duration = var.max_session_duration
  description          = "GitHub Actions deploy/e2e role, trust scoped to ${join(", ", local.subjects)}"
  tags                 = local.tags

  # The boundary ARN is built (see local.created_boundary_arn), so the policy
  # must exist before a role names it.
  depends_on = [aws_iam_policy.boundary]
}

resource "aws_iam_role_policy_attachment" "deploy" {
  for_each   = var.create_deploy_role ? toset(var.managed_policy_arns) : toset([])
  role       = aws_iam_role.deploy[0].name
  policy_arn = each.value
}

################################################################################
# Plan role — assumed by the CI plan matrix on pull requests
#
# SEPARATE from the deploy role on purpose. The plan matrix runs on
# `pull_request`, and the deploy role deliberately does not trust that context:
# it can provision and destroy EKS and IAM, and a fork's PR or an untrusted
# branch must never assume it. Widening the deploy role's trust to reach the
# plan matrix would hand every PR the role that can tear down the substrate.
#
# So the plan matrix gets its own role, trusted from a GitHub ENVIRONMENT rather
# than from the pull_request context directly. An environment is the escape
# hatch the deploy leaf already prescribes for jobs that need a role from a
# non-environment context, and it is human-gateable: required reviewers on the
# `plan` environment mean a PR from an untrusted branch waits for approval
# before any AWS credential is issued. The sub becomes
# repo:<org>/<repo>:environment:plan, never a bare branch or pull_request claim.
#
# That holds for the development account only. ci.yml's PR plan job declares
# `plan` from any branch, so in an account holding staging or production the
# plan role trusts exactly environment:drift, from landing-zone alone, instead:
# drift.yml declares it, and landing-zone's drift environment admits main only,
# so no pull request reaches a staging or production account's state. The
# validations tie the claim to var.account_environments — every environment the
# ACCOUNT holds, computed from the tree by envcommon — rather than to the leaf's
# own environment, because the role is account-global and the account's one
# state bucket holds every environment's state: a leaf in the development
# directory of the network or backup account cannot ship the development trust
# either. An account holding neither (management, fleet, shared-services) gets
# no plan role.
#
# READ SCOPE, stated rather than discovered: ReadOnlyAccess is account-wide read,
# and that includes the Terraform state bucket. State holds plaintext values for
# every resource whose provider does not mark an attribute sensitive. A principal
# that can run `terragrunt plan` can already read state by construction — plan
# reads state — so this is a property of letting CI plan at all, not a defect in
# this role. It is written down here so the next reader does not discover it.
################################################################################

locals {
  plan_subjects = flatten([
    for r in var.github_repos : [
      for c in var.plan_allowed_subject_claims : "repo:${var.github_org}/${r}:${c}"
    ]
  ])
}

data "aws_iam_policy_document" "plan_trust" {
  count = var.create_plan_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.plan_subjects
    }
  }
}

resource "aws_iam_role" "plan" {
  count                = var.create_plan_role ? 1 : 0
  name                 = var.plan_role_name
  assume_role_policy   = data.aws_iam_policy_document.plan_trust[0].json
  permissions_boundary = local.permissions_boundary_arn
  max_session_duration = var.max_session_duration
  description          = "GitHub Actions plan role (read-only), trust scoped to ${join(", ", local.plan_subjects)}"
  tags                 = local.tags

  depends_on = [aws_iam_policy.boundary]
}

resource "aws_iam_role_policy_attachment" "plan" {
  for_each   = var.create_plan_role ? toset(var.plan_managed_policy_arns) : toset([])
  role       = aws_iam_role.plan[0].name
  policy_arn = each.value
}

################################################################################
# ECR Public pull role — assumed by CI jobs that pull from public.ecr.aws
#
# ECR Public meters an anonymous client by its source address, and a hosted
# runner shares its address with every other workflow scheduled onto it, so an
# anonymous pull can arrive with that address's data allowance already spent and
# fail with TOOMANYREQUESTS no retry outlasts. An authenticated pull is metered
# against the AWS account that issued the token instead.
#
# The role trusts pull_request, which the deploy and plan roles refuse. That
# holds because of what the role can do: its only permissions mint an ECR Public
# authorization token, and that token reads public repositories — data any
# anonymous client can already read. A pull request that obtains it gains a
# quota, never access. The role carries no managed policy and no permissions
# boundary input, so nothing attached later can widen it from this component.
#
# GitHub issues no OIDC token to a workflow running for a pull request from a
# fork, so fork pull requests never reach this trust; those jobs pull
# anonymously.
################################################################################

locals {
  ecr_public_pull_subjects = flatten([
    for r in var.ecr_public_pull_repos : [
      for c in var.ecr_public_pull_subject_claims : "repo:${var.github_org}/${r}:${c}"
    ]
  ])
}

data "aws_iam_policy_document" "ecr_public_pull_trust" {
  count = var.create_ecr_public_pull_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.ecr_public_pull_subjects
    }
  }
}

# An authenticated pull from public.ecr.aws needs exactly these two actions, and
# both are account-level calls with no resource to scope to, so the resource is
# "*":
# https://docs.aws.amazon.com/AmazonECR/latest/public/docker-pull-ecr-image.html
# ECR Public issues tokens from us-east-1 only, so the caller requests the token
# there whatever region the rest of its job uses:
# https://docs.aws.amazon.com/AmazonECR/latest/public/public-registry-auth.html
data "aws_iam_policy_document" "ecr_public_pull" {
  count = var.create_ecr_public_pull_role ? 1 : 0

  statement {
    sid    = "EcrPublicPullToken"
    effect = "Allow"
    actions = [
      "ecr-public:GetAuthorizationToken",
      "sts:GetServiceBearerToken",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "ecr_public_pull" {
  count                = var.create_ecr_public_pull_role ? 1 : 0
  name                 = var.ecr_public_pull_role_name
  assume_role_policy   = data.aws_iam_policy_document.ecr_public_pull_trust[0].json
  max_session_duration = var.max_session_duration
  description          = "GitHub Actions ECR Public pull role, trust scoped to ${join(", ", local.ecr_public_pull_subjects)}"
  tags                 = local.tags
}

resource "aws_iam_role_policy" "ecr_public_pull" {
  count  = var.create_ecr_public_pull_role ? 1 : 0
  name   = "ecr-public-pull"
  role   = aws_iam_role.ecr_public_pull[0].id
  policy = data.aws_iam_policy_document.ecr_public_pull[0].json
}
