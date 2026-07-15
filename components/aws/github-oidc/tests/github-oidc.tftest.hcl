# Unit tests for github-oidc — the trust anchor that lets GitHub Actions workflows
# assume an AWS role via OIDC. The single load-bearing control here is the trust
# policy on aws_iam_role.deploy: it is the ONLY thing standing between "our CI in
# our repos" and "any GitHub Actions token on the entire internet". A silent
# regression that widens the `sub` claim to `*` / `repo:*/*`, drops the `aud`
# check, or points the Federated principal at anything but the GitHub OIDC provider
# is a straight-line CI-auth escalation: a fork or an unrelated repo could mint
# credentials for this account. These tests pin every clause of that trust doc.
#
# PROVIDER STRATEGY B: the trust policy is rendered by
# data.aws_iam_policy_document.trust. A mock_provider would mangle that data source
# into a non-JSON placeholder, so we use a REAL credential-less AWS provider (no
# account, no network — all skip_* flags on) so aws_iam_policy_document renders
# locally for real, and override_data ONLY the two API-backed reads
# (aws_caller_identity + aws_iam_openid_connect_provider) so the account-qualified
# ARNs resolve without STS. create_oidc_provider = false routes the provider ARN
# through the overridable data source (the create=true path yields an unknown ARN
# at plan time). Every assertion below decodes aws_iam_role.deploy.assume_role_policy
# — the actual rendered, wired-up trust JSON — never an override'd stub value.

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

# API-backed reads, replaced so no STS/IAM call happens at plan. These are inputs
# to the trust doc, not the thing under assertion — the component's routing of them
# into the policy is what we test.
override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/test"
    user_id    = "AIDTEST"
  }
}

override_data {
  target = data.aws_iam_openid_connect_provider.github
  values = {
    arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
}

variables {
  environment          = "dev"
  region               = "us-west-2"
  team                 = "platform"
  github_org           = "nanohype"
  github_repos         = ["landing-zone", "rackctl"]
  create_oidc_provider = false
}

# INVARIANT 1: the trust is scoped to the configured repos AND to the allowed
# subject claims via a StringLike on the `sub` claim — exactly
# repo:<org>/<repo>:<claim> for the cartesian product, and NOTHING else. This is THE
# control. The default claim set is environment-gated deploys + tag pushes; a
# widened sub (bare ":*", "*", or "repo:*/*") lets pull_request / any-branch / any
# repo assume the role. Asserted structurally: find the AssumeRoleWithWebIdentity
# statement and compare the whole sub set.
run "trust_sub_scoped_to_configured_repos_and_claims" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.deploy.assume_role_policy).Statement :
      s if toset(flatten([
        try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])
        ])) == toset([
        "repo:nanohype/landing-zone:environment:*",
        "repo:nanohype/landing-zone:ref:refs/tags/*",
        "repo:nanohype/rackctl:environment:*",
        "repo:nanohype/rackctl:ref:refs/tags/*",
      ])
    ]) == 1
    error_message = "trust sub must StringLike-pin exactly repo:nanohype/{landing-zone,rackctl}:{environment:*,ref:refs/tags/*}; any other set (dropped/added/widened repo or claim) is a CI-auth boundary change"
  }

  # Belt-and-suspenders on the escalation itself: no statement's sub may contain a
  # bare "*", the cross-org/repo wildcard "repo:*/*", the broad per-repo ":*", or a
  # pull_request context (an untrusted PR must never assume a deploy role).
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.deploy.assume_role_policy).Statement :
      length([
        for sub in flatten([try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])]) :
        sub if sub == "*" || sub == "repo:*/*"
        || can(regex("^repo:[^:]+/[^:]+:\\*$", sub)) # bare per-repo :* (claim is a lone wildcard)
        || endswith(sub, ":pull_request")
      ]) == 0
    ])
    error_message = "trust sub must never contain \"*\", \"repo:*/*\", a bare per-repo \":*\", or a \":pull_request\" context — each re-opens the deploy role to untrusted workflows"
  }
}

# INVARIANT 1b: the claim set is variable-driven, not hardcoded. Narrowing to a
# single environment must produce exactly that sub set — proving allowed_subject_claims
# actually drives the trust rather than a coincidentally-correct default.
run "trust_sub_honors_allowed_subject_claims" {
  command = plan

  variables {
    github_repos           = ["landing-zone"]
    allowed_subject_claims = ["environment:production"]
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.deploy.assume_role_policy).Statement :
      s if toset(flatten([
        try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])
      ])) == toset(["repo:nanohype/landing-zone:environment:production"])
    ]) == 1
    error_message = "narrowing allowed_subject_claims to [environment:production] must scope the trust sub to exactly that subject"
  }
}

# INVARIANT 2: the audience is pinned (StringEquals aud == sts.amazonaws.com) and
# the Federated principal is the GitHub OIDC provider, with Effect=Allow on
# sts:AssumeRoleWithWebIdentity only. Dropping aud lets tokens minted for a
# different audience through; repointing the principal (type AWS, or a "*"
# identifier) breaks the federation anchor entirely.
run "trust_aud_pinned_and_federated_principal" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.deploy.assume_role_policy).Statement :
      s if try(s.Condition.StringEquals["token.actions.githubusercontent.com:aud"], "") == "sts.amazonaws.com"
    ]) == 1
    error_message = "trust must StringEquals-pin the aud claim to sts.amazonaws.com exactly once"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.deploy.assume_role_policy).Statement :
      s if try(s.Principal.Federated, "") == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      && try(s.Effect, "") == "Allow"
      && try(s.Action, "") == "sts:AssumeRoleWithWebIdentity"
    ]) == 1
    error_message = "trust must Allow sts:AssumeRoleWithWebIdentity for a Federated principal that is the GitHub OIDC provider ARN — not principal type AWS, not a wildcard identifier"
  }
}

# INVARIANT 3 (guardrail): github_repos is validated non-empty. An empty list
# renders an empty sub condition, which AWS silently DROPS — leaving only the aud
# check and making the role assumable by ANY GitHub Actions workflow. The variable
# validation is the enforcement point; this run proves it rejects [].
run "empty_github_repos_rejected" {
  command = plan

  variables {
    github_repos = []
  }

  expect_failures = [
    var.github_repos,
  ]
}

# INVARIANT 3b (guardrail): allowed_subject_claims is validated non-empty for the
# same reason — an empty claim set renders an empty sub condition, which AWS drops,
# leaving only the aud check and making the role assumable by any GitHub Actions
# workflow. The variable validation is the enforcement point; this proves it rejects [].
run "empty_allowed_subject_claims_rejected" {
  command = plan

  variables {
    allowed_subject_claims = []
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}
