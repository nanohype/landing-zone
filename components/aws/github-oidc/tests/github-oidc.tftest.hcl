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
# locally for real, and override_data ONLY the API-backed OIDC-provider read
# (aws_iam_openid_connect_provider) so the account-qualified provider ARN
# resolves without STS. create_oidc_provider = false routes the provider ARN
# through the overridable data source (the create=true path yields an unknown ARN
# at plan time). Every assertion below decodes aws_iam_role.deploy[0].assume_role_policy
# — the actual rendered, wired-up trust JSON — never an override'd stub value.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

# API-backed read, replaced so no STS/IAM call happens at plan. This is an input
# to the trust doc, not the thing under assertion — the component's routing of it
# into the policy is what we test.
override_data {
  target = data.aws_iam_openid_connect_provider.github
  values = {
    arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
}

variables {
  environment          = "development"
  region               = "us-east-1"
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
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
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
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
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
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
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
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
      s if try(s.Condition.StringEquals["token.actions.githubusercontent.com:aud"], "") == "sts.amazonaws.com"
    ]) == 1
    error_message = "trust must StringEquals-pin the aud claim to sts.amazonaws.com exactly once"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
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

# ─────────────────────────── plan role ───────────────────────────
#
# The plan role is the credential the CI plan matrix assumes on pull requests.
# Its trust is the whole control: the matrix runs on `pull_request`, a context the
# DEPLOY role deliberately refuses because that role can provision and destroy EKS
# and IAM. These assertions pin the two properties that keep the separation real —
# the plan role never trusts a pull_request/branch/wildcard claim, and widening it
# never silently widens the deploy role (or vice versa).

run "plan_role_trusts_only_the_environment_claim" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement :
      contains(
        tolist(try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])),
        "repo:nanohype/landing-zone:environment:plan"
      )
    ])
    error_message = "the plan role's trust must scope sub to repo:nanohype/landing-zone:environment:plan — a GitHub Environment, which can carry required reviewers"
  }
}

run "plan_role_never_trusts_pull_request_or_a_bare_branch" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement :
      alltrue([
        for sub in tolist(try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])) :
        !endswith(sub, ":pull_request") && !strcontains(sub, ":ref:refs/heads/") && sub != "*" && !endswith(sub, ":*")
      ])
    ])
    error_message = "the plan role must NOT trust :pull_request, a bare branch ref, or a wildcard sub — on a public repo any of those hands an AWS credential to an arbitrary PR"
  }
}

run "plan_role_is_read_only" {
  command = plan

  assert {
    condition     = contains(var.plan_managed_policy_arns, "arn:aws:iam::aws:policy/ReadOnlyAccess")
    error_message = "the plan role must carry ReadOnlyAccess — a plan reads, it does not write"
  }

  assert {
    condition = alltrue([
      for a in var.plan_managed_policy_arns :
      !strcontains(a, "AdministratorAccess") && !strcontains(a, "PowerUserAccess")
    ])
    error_message = "the plan role must not carry AdministratorAccess or PowerUserAccess — the point of a separate plan role is that a pull-request-reachable credential cannot write"
  }
}

run "deploy_role_trust_is_unchanged_by_the_plan_role" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
      alltrue([
        for sub in tolist(try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])) :
        !strcontains(sub, "environment:plan")
      ])
    ])
    error_message = "the deploy role must not have acquired the plan role's environment claim — the two roles exist to keep those trust surfaces separate"
  }
}

# ─────────────────────────── ECR Public pull role ───────────────────────────
#
# The pull role is the one role here that trusts pull_request. What keeps that
# safe is its permission set: an ECR Public authorization token reads public
# repositories and nothing else. These assertions pin both halves — the exact
# subjects it trusts, and the exact two actions it holds — plus the guardrails
# that keep an empty or wildcard claim set from reaching AWS, and the default
# that leaves the role absent until a leaf asks for it.

run "ecr_public_pull_role_absent_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role.ecr_public_pull) == 0 && length(aws_iam_role_policy.ecr_public_pull) == 0
    error_message = "the ECR Public pull role must not exist unless create_ecr_public_pull_role is set"
  }
}

run "ecr_public_pull_trust_subjects_are_exact" {
  command = plan

  variables {
    create_ecr_public_pull_role = true
    ecr_public_pull_repos       = ["eks-gitops"]
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.ecr_public_pull[0].assume_role_policy).Statement :
      s if toset(flatten([
        try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])
        ])) == toset([
        "repo:nanohype/eks-gitops:pull_request",
        "repo:nanohype/eks-gitops:ref:refs/heads/main",
      ])
    ]) == 1
    error_message = "the pull role's sub must StringLike-pin exactly repo:nanohype/eks-gitops:{pull_request,ref:refs/heads/main}"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.ecr_public_pull[0].assume_role_policy).Statement :
      alltrue([
        for sub in flatten([try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])]) :
        sub != "*" && sub != "repo:*/*" && !can(regex("^repo:[^:]+/[^:]+:\\*$", sub))
      ])
    ])
    error_message = "the pull role's sub must never contain \"*\", \"repo:*/*\", or a bare per-repo \":*\""
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.ecr_public_pull[0].assume_role_policy).Statement :
      s if try(s.Condition.StringEquals["token.actions.githubusercontent.com:aud"], "") == "sts.amazonaws.com"
      && try(s.Principal.Federated, "") == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      && try(s.Action, "") == "sts:AssumeRoleWithWebIdentity"
      && try(s.Effect, "") == "Allow"
    ]) == 1
    error_message = "the pull role must Allow sts:AssumeRoleWithWebIdentity for the GitHub OIDC provider with aud pinned to sts.amazonaws.com"
  }
}

run "ecr_public_pull_policy_holds_exactly_the_token_actions" {
  command = plan

  variables {
    create_ecr_public_pull_role = true
    ecr_public_pull_repos       = ["eks-gitops"]
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.ecr_public_pull[0].policy).Statement : flatten([s.Action])
    ])) == toset(["ecr-public:GetAuthorizationToken", "sts:GetServiceBearerToken"])
    error_message = "the pull role's policy must grant exactly ecr-public:GetAuthorizationToken and sts:GetServiceBearerToken — any other action widens a pull_request-reachable credential"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.ecr_public_pull[0].policy).Statement :
      s.Effect == "Allow"
    ])
    error_message = "the pull role's policy must hold Allow statements only"
  }
}

run "ecr_public_pull_only_leaf_creates_no_other_role" {
  command = plan

  variables {
    create_deploy_role          = false
    create_plan_role            = false
    create_ecr_public_pull_role = true
    ecr_public_pull_repos       = ["eks-gitops"]
  }

  assert {
    condition     = length(aws_iam_role.deploy) == 0 && length(aws_iam_role.plan) == 0 && length(aws_iam_role.ecr_public_pull) == 1
    error_message = "with the deploy and plan roles switched off, the component must plan the pull role alone"
  }

  assert {
    condition     = output.deploy_role_arn == null && output.plan_role_arn == null
    error_message = "the deploy and plan role outputs must be null when those roles are not created"
  }
}

run "ecr_public_pull_empty_repos_rejected" {
  command = plan

  variables {
    create_ecr_public_pull_role = true
    ecr_public_pull_repos       = []
  }

  expect_failures = [
    var.ecr_public_pull_repos,
  ]
}

run "ecr_public_pull_bare_wildcard_claim_rejected" {
  command = plan

  variables {
    create_ecr_public_pull_role    = true
    ecr_public_pull_repos          = ["eks-gitops"]
    ecr_public_pull_subject_claims = ["*"]
  }

  expect_failures = [
    var.ecr_public_pull_subject_claims,
  ]
}
