data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

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
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  max_session_duration = var.max_session_duration
  description          = "GitHub Actions deploy/e2e role, trust scoped to ${join(", ", local.subjects)}"
  tags                 = local.tags
}

resource "aws_iam_role_policy_attachment" "deploy" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.deploy.name
  policy_arn = each.value
}
