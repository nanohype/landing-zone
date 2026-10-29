locals {
  # Subject claims the deploy role trusts: the cartesian product of the configured
  # repos and the allowed claim suffixes (repo:<org>/<repo>:<claim>). The default
  # claim set is environment-gated deploys + tag pushes — NOT a bare :*, which would
  # also trust pull_request and every branch context. Only Actions workflows in
  # these repos, in one of these contexts, may assume the role.
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
# Deploy role — assumed by GitHub Actions to provision/destroy the substrate
#
# Trust is scoped to workflows in the configured repos ONLY (the load-bearing
# control). The role ships with NO permissions — attach the managed policies CI
# needs via managed_policy_arns (and ideally a permissions boundary). Inert until
# you do, which is the safe default for a role that isn't used by default.
#
# NOTE: the org currently runs `deploy` and the e2e as LOCAL execs with SSO
# credentials — neither assumes this role. It exists for the OPTIONAL GitHub
# Actions CI path; its ARN feeds the AWS_ROLE_ARN / E2E_AWS_ROLE_ARN repo vars.
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
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  max_session_duration = var.max_session_duration
  description          = "GitHub Actions deploy/e2e role, trust scoped to ${join(", ", local.subjects)}"
  tags                 = local.tags
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
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  max_session_duration = var.max_session_duration
  description          = "GitHub Actions plan role (read-only), trust scoped to ${join(", ", local.plan_subjects)}"
  tags                 = local.tags
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
