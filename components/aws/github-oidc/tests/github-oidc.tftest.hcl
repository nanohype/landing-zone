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

# The account id the permissions boundary builds its own ARN and the protected
# role ARNs from (data.aws_caller_identity, read only when
# create_permissions_boundary is set). Replaced for the same reason as above.
override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

variables {
  environment          = "development"
  account_environments = ["development"]
  region               = "us-east-1"
  team                 = "platform"
  github_org           = "nanohype"
  github_repos         = ["landing-zone", "rackctl"]
  create_oidc_provider = false
}

# INVARIANT 1: the trust is scoped to the configured repos AND to the allowed
# subject claims via a StringLike on the `sub` claim — exactly
# repo:<org>/<repo>:<claim> for the cartesian product, and NOTHING else. This is THE
# control. The default claim set is the four GitHub Environments deploy.yml,
# destroy.yml and e2e.yml declare; a widened sub ("environment:*", which also
# admits the any-branch plan environment, a tag ref, a bare ":*", "*", or
# "repo:*/*") lets an untrusted branch / tag / pull_request / repo assume the role.
# Asserted structurally: find the AssumeRoleWithWebIdentity statement and compare
# the whole sub set.
run "trust_sub_scoped_to_configured_repos_and_claims" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
      s if toset(flatten([
        try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])
        ])) == toset([
        "repo:nanohype/landing-zone:environment:development",
        "repo:nanohype/landing-zone:environment:staging",
        "repo:nanohype/landing-zone:environment:production",
        "repo:nanohype/landing-zone:environment:e2e",
        "repo:nanohype/rackctl:environment:development",
        "repo:nanohype/rackctl:environment:staging",
        "repo:nanohype/rackctl:environment:production",
        "repo:nanohype/rackctl:environment:e2e",
      ])
    ]) == 1
    error_message = "trust sub must StringLike-pin exactly repo:nanohype/{landing-zone,rackctl}:environment:{development,staging,production,e2e}; any other set (dropped/added/widened repo or claim) is a CI-auth boundary change"
  }

  # Belt-and-suspenders on the escalation itself: no statement's sub may contain a
  # bare "*", the cross-org/repo wildcard "repo:*/*", the broad per-repo ":*", a
  # pull_request context (an untrusted PR must never assume a deploy role), any
  # wildcard at all in the default set, or a tag ref.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
      length([
        for sub in flatten([try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])]) :
        sub if sub == "*" || sub == "repo:*/*"
        || can(regex("^repo:[^:]+/[^:]+:\\*$", sub)) # bare per-repo :* (claim is a lone wildcard)
        || endswith(sub, ":pull_request")
        || strcontains(sub, "*") || strcontains(sub, "?")
        || strcontains(sub, ":ref:refs/tags/")
      ]) == 0
    ])
    error_message = "the default trust sub must never contain \"*\", \"repo:*/*\", a bare per-repo \":*\", a \":pull_request\" context, any wildcard, or a tag ref — each re-opens the deploy role to workflows that are not the gated deploy/destroy/e2e jobs"
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

# INVARIANT 3c (guardrail): allowed_subject_claims is an ALLOWLIST — every entry
# must be an exact "environment:<name>" claim with no StringLike wildcard. A
# wildcard admits any environment name a branch's workflow declares, and GitHub
# creates that environment, unprotected, the first time a workflow names it, so
# "environment:prod*" is as open as "environment:*". A pull_request or ref: claim
# is held by anyone who can open that pull request or push that ref. And
# "environment:plan", which ci.yml's PR plan job and drift.yml declare from any
# branch, is refused in every letter case (GitHub environment names are
# case-insensitive). Each run below is one way back in; the validation must
# reject them all — including when the bad claim sits beside a good one.
run "plan_environment_claim_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["environment:production", "environment:plan"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "plan_environment_claim_other_case_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["environment:Plan"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "drift_environment_claim_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["environment:staging", "environment:drift"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "drift_environment_claim_other_case_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["environment:DRIFT"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "environment_wildcard_claim_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["environment:*"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "environment_prefix_wildcard_claim_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["environment:production", "environment:prod*"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "bare_wildcard_claim_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["*"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "partial_wildcard_claim_covering_plan_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["environment:pla?"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "pull_request_claim_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["pull_request"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "tag_ref_claim_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["ref:refs/tags/*"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

run "exact_branch_ref_claim_rejected" {
  command = plan

  variables {
    allowed_subject_claims = ["ref:refs/heads/main"]
  }

  expect_failures = [
    var.allowed_subject_claims,
  ]
}

# INVARIANT 3d (guardrail): github_repos and github_org are literal names. Each
# lands verbatim in the StringLike sub, so "landing-zone*" renders
# repo:<org>/landing-zone*:<claim>, which matches
# repo:<org>/landing-zone:environment:plan whatever allowed_subject_claims holds —
# a bypass of every claim check above.
run "wildcard_github_repo_rejected" {
  command = plan

  variables {
    github_repos           = ["landing-zone*"]
    allowed_subject_claims = ["environment:production"]
  }

  expect_failures = [
    var.github_repos,
  ]
}

run "wildcard_github_org_rejected" {
  command = plan

  variables {
    github_org = "nano*"
  }

  expect_failures = [
    var.github_org,
  ]
}

# INVARIANT 3e (precision): the guard refuses wildcards, non-environment claims
# and the plan environment — not every claim near them. An exact environment name
# containing a regex metacharacter ("pl.n"), one that merely starts with "plan"
# ("planning"), and an ordinary exact name are accepted and rendered as given.
# Without this, the validation could reject everything and the rejection runs
# above would still pass.
run "exact_environment_claims_accepted" {
  command = plan

  variables {
    github_repos           = ["landing-zone"]
    allowed_subject_claims = ["environment:prod", "environment:pl.n", "environment:planning"]
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
      s if toset(flatten([
        try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])
        ])) == toset([
        "repo:nanohype/landing-zone:environment:prod",
        "repo:nanohype/landing-zone:environment:pl.n",
        "repo:nanohype/landing-zone:environment:planning",
      ])
    ]) == 1
    error_message = "exact environment claims other than plan must be accepted and rendered as given"
  }
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

# ───────────────────── plan role: exact-environment allowlist ─────────────────────
#
# plan_allowed_subject_claims carries the same allowlist as allowed_subject_claims:
# every entry an exact "environment:<name>". The plan role reads every object in
# its account, state included, so a wildcard environment (which GitHub creates,
# unprotected, the first time a workflow names it), a pull_request claim or a ref:
# claim would hand that read to whoever can open the pull request, push the ref or
# invent the environment. Each run is one way back in; the validation must refuse
# them all, including beside a valid claim.

run "plan_bare_wildcard_claim_rejected" {
  command = plan

  variables {
    plan_allowed_subject_claims = ["*"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "plan_environment_wildcard_claim_rejected" {
  command = plan

  variables {
    plan_allowed_subject_claims = ["environment:plan", "environment:*"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "plan_partial_wildcard_claim_rejected" {
  command = plan

  variables {
    plan_allowed_subject_claims = ["environment:pla?"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "plan_pull_request_claim_rejected" {
  command = plan

  variables {
    plan_allowed_subject_claims = ["environment:plan", "pull_request"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "plan_branch_ref_claim_rejected" {
  command = plan

  variables {
    plan_allowed_subject_claims = ["ref:refs/heads/main"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "plan_empty_claims_rejected" {
  command = plan

  variables {
    plan_allowed_subject_claims = []
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

# ─────────────────── plan role: the claim follows the account ───────────────────
#
# A plan role in an account holding staging or production reads that account's
# one state bucket, every environment's state included, so it trusts exactly
# environment:drift (drift.yml, main-only) from landing-zone alone, and never
# environment:plan (ci.yml's PR plan job, any branch). The validation reads
# var.account_environments — every environment the account holds, which
# live/_envcommon/aws/github-oidc.hcl computes from the tree — not the leaf's
# own directory, so a leaf in the development directory of the network or
# backup account is held to the production rule. Every arm is pinned here, with
# the rendered trust asserted on each accepted arm.

run "development_plan_role_trusts_the_plan_environment" {
  command = plan

  variables {
    environment          = "development"
    account_environments = ["development"]
    github_repos         = ["landing-zone"]
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement :
      s if toset(flatten([
        try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])
      ])) == toset(["repo:nanohype/landing-zone:environment:plan"])
    ]) == 1
    error_message = "the development plan role must trust exactly repo:nanohype/landing-zone:environment:plan by default"
  }
}

run "staging_plan_role_trusts_exactly_the_drift_environment" {
  command = plan

  variables {
    environment                 = "staging"
    account_environments        = ["staging"]
    github_repos                = ["landing-zone"]
    allowed_subject_claims      = ["environment:staging"]
    plan_allowed_subject_claims = ["environment:drift"]
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement :
      s if toset(flatten([
        try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])
      ])) == toset(["repo:nanohype/landing-zone:environment:drift"])
    ]) == 1
    error_message = "a staging plan role must trust exactly repo:nanohype/landing-zone:environment:drift"
  }
}

run "production_plan_role_trusts_exactly_the_drift_environment" {
  command = plan

  variables {
    environment                 = "production"
    account_environments        = ["production"]
    github_repos                = ["landing-zone"]
    allowed_subject_claims      = ["environment:production"]
    plan_allowed_subject_claims = ["environment:drift"]
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement :
      s if toset(flatten([
        try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])
      ])) == toset(["repo:nanohype/landing-zone:environment:drift"])
    ]) == 1
    error_message = "a production plan role must trust exactly repo:nanohype/landing-zone:environment:drift"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.deploy[0].assume_role_policy).Statement :
      alltrue([
        for sub in flatten([try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])]) :
        !strcontains(sub, "environment:drift")
      ])
    ])
    error_message = "the deploy role must not acquire the plan role's drift claim"
  }
}

# The shared-account case: a leaf in the DEVELOPMENT directory of an account that
# also holds staging and production (network, backup) is held to the drift rule,
# because the role it creates reads the same account-wide state bucket.
run "development_directory_of_a_shared_account_trusts_exactly_the_drift_environment" {
  command = plan

  variables {
    environment                 = "development"
    account_environments        = ["development", "hub", "production", "staging"]
    github_repos                = ["landing-zone"]
    allowed_subject_claims      = ["environment:development"]
    plan_allowed_subject_claims = ["environment:drift"]
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement :
      s if toset(flatten([
        try(s.Condition.StringLike["token.actions.githubusercontent.com:sub"], [])
      ])) == toset(["repo:nanohype/landing-zone:environment:drift"])
    ]) == 1
    error_message = "a plan role in an account holding production must trust exactly repo:nanohype/landing-zone:environment:drift, whichever environment directory its leaf sits in"
  }
}

run "development_directory_of_a_shared_account_with_the_default_plan_claim_rejected" {
  command = plan

  variables {
    environment          = "development"
    account_environments = ["development", "hub", "production", "staging"]
    github_repos         = ["landing-zone"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "hub_directory_of_a_shared_account_with_the_plan_claim_rejected" {
  command = plan

  variables {
    environment                 = "hub"
    account_environments        = ["development", "hub", "production", "staging"]
    github_repos                = ["landing-zone"]
    plan_allowed_subject_claims = ["environment:plan"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

# The default ["environment:plan"] left in place by a production leaf is the copy
# of the development pattern this validation exists to stop.
run "production_plan_role_with_the_default_plan_claim_rejected" {
  command = plan

  variables {
    environment          = "production"
    account_environments = ["production"]
    github_repos         = ["landing-zone"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "staging_plan_role_with_the_plan_claim_rejected" {
  command = plan

  variables {
    environment                 = "staging"
    account_environments        = ["staging"]
    github_repos                = ["landing-zone"]
    plan_allowed_subject_claims = ["environment:plan"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "staging_plan_role_with_the_plan_claim_beside_drift_rejected" {
  command = plan

  variables {
    environment                 = "staging"
    account_environments        = ["staging"]
    github_repos                = ["landing-zone"]
    plan_allowed_subject_claims = ["environment:drift", "environment:Plan"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "production_plan_role_with_another_environment_rejected" {
  command = plan

  variables {
    environment                 = "production"
    account_environments        = ["production"]
    github_repos                = ["landing-zone"]
    plan_allowed_subject_claims = ["environment:production"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

run "production_plan_role_with_a_differently_cased_drift_rejected" {
  command = plan

  variables {
    environment                 = "production"
    account_environments        = ["production"]
    github_repos                = ["landing-zone"]
    plan_allowed_subject_claims = ["environment:Drift"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

# The drift trust is safe because landing-zone's drift environment is main-only.
# Any other listed repo would get repo:<org>/<repo>:environment:drift, and in that
# repo a workflow on any branch that names the environment creates it unprotected.
run "production_plan_role_trusting_a_second_repo_rejected" {
  command = plan

  variables {
    environment                 = "production"
    account_environments        = ["production"]
    github_repos                = ["landing-zone", "rackctl"]
    allowed_subject_claims      = ["environment:production"]
    plan_allowed_subject_claims = ["environment:drift"]
  }

  expect_failures = [
    var.github_repos,
  ]
}

run "staging_plan_role_trusting_another_repo_only_rejected" {
  command = plan

  variables {
    environment                 = "staging"
    account_environments        = ["staging"]
    github_repos                = ["rackctl"]
    allowed_subject_claims      = ["environment:staging"]
    plan_allowed_subject_claims = ["environment:drift"]
  }

  expect_failures = [
    var.github_repos,
  ]
}

# A deploy role for other repos in a production account is still possible: the
# repo restriction binds the plan role only.
run "production_leaf_without_a_plan_role_may_list_other_repos" {
  command = plan

  variables {
    environment            = "production"
    account_environments   = ["production"]
    github_repos           = ["landing-zone", "rackctl"]
    allowed_subject_claims = ["environment:production"]
    create_plan_role       = false
  }

  assert {
    condition     = length(aws_iam_role.plan) == 0 && length(aws_iam_role.deploy) == 1
    error_message = "with create_plan_role false, a production leaf may list other repos for its deploy role"
  }
}

run "development_plan_role_with_the_drift_claim_rejected" {
  command = plan

  variables {
    environment                 = "development"
    account_environments        = ["development"]
    plan_allowed_subject_claims = ["environment:plan", "environment:drift"]
  }

  expect_failures = [
    var.plan_allowed_subject_claims,
  ]
}

# The management, fleet and shared-services accounts hold neither development
# alone nor staging or production. No workflow plans them, so they get no plan
# role at all, whatever claim is offered.
run "hub_account_plan_role_rejected" {
  command = plan

  variables {
    environment          = "hub"
    account_environments = ["hub"]
  }

  expect_failures = [
    var.create_plan_role,
  ]
}

run "org_account_plan_role_with_an_invented_environment_rejected" {
  command = plan

  variables {
    environment                 = "org"
    account_environments        = ["org"]
    plan_allowed_subject_claims = ["environment:org-plan"]
  }

  expect_failures = [
    var.create_plan_role,
  ]
}

run "shared_account_plan_role_with_the_drift_claim_rejected" {
  command = plan

  variables {
    environment                 = "shared"
    account_environments        = ["shared"]
    plan_allowed_subject_claims = ["environment:drift"]
  }

  expect_failures = [
    var.create_plan_role,
  ]
}

run "hub_account_without_a_plan_role_accepted" {
  command = plan

  variables {
    environment          = "hub"
    account_environments = ["hub"]
    create_plan_role     = false
  }

  assert {
    condition     = length(aws_iam_role.plan) == 0
    error_message = "a hub account leaf with create_plan_role false must plan without a plan role"
  }
}

# The environment rules bind the plan role only. A production leaf that creates
# no plan role (the ECR Public pull leaf's shape) is not refused for the unused
# default claim.
run "production_leaf_without_a_plan_role_accepts_the_unused_default" {
  command = plan

  variables {
    environment            = "production"
    account_environments   = ["production"]
    allowed_subject_claims = ["environment:production"]
    create_plan_role       = false
  }

  assert {
    condition     = length(aws_iam_role.plan) == 0 && length(aws_iam_role.deploy) == 1
    error_message = "with create_plan_role false, a production leaf must plan without a plan role"
  }
}

# ─────────────────── environment and account_environments vocabulary ───────────────────
#
# The rules above are keyed on exact names. A misspelt environment, or an account
# list naming one, would fall outside every rule, so both are held to env.hcl's
# vocabulary, and the leaf's environment must be one its account holds.

run "capitalised_environment_rejected" {
  command = plan

  variables {
    environment                 = "Staging"
    account_environments        = ["development"]
    plan_allowed_subject_claims = ["environment:production"]
  }

  expect_failures = [
    var.environment,
  ]
}

run "abbreviated_account_environment_rejected" {
  command = plan

  variables {
    environment                 = "production"
    account_environments        = ["prod", "production"]
    github_repos                = ["landing-zone"]
    plan_allowed_subject_claims = ["environment:drift"]
  }

  expect_failures = [
    var.account_environments,
  ]
}

run "empty_account_environments_rejected" {
  command = plan

  variables {
    account_environments = []
  }

  expect_failures = [
    var.account_environments,
  ]
}

run "account_environments_missing_the_leaf_environment_rejected" {
  command = plan

  variables {
    environment          = "production"
    account_environments = ["development"]
  }

  expect_failures = [
    var.account_environments,
  ]
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

# ─────────────────────────── permissions boundary ───────────────────────────
#
# The workload-development deploy role carries AdministratorAccess, and what
# keeps that from being "every development job owns the account's CI trust" is
# the boundary this component creates. These runs pin the four things that make
# it a ceiling rather than a label: it is on BOTH roles (by the exact ARN the
# policy is created under), it allows everything so the attached policies stay
# the grant, every deny statement is present with its resources, and
# AdministratorAccess without a boundary does not plan at all. The boundary
# policy is decoded from the rendered aws_iam_policy_document, the same JSON
# aws_iam_policy.boundary is created with.

run "no_boundary_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_policy.boundary) == 0
    error_message = "no boundary policy may be created unless create_permissions_boundary is set"
  }

  assert {
    condition     = aws_iam_role.deploy[0].permissions_boundary == null && aws_iam_role.plan[0].permissions_boundary == null
    error_message = "with no boundary input, neither role may carry a boundary"
  }

  assert {
    condition     = output.permissions_boundary_arn == null
    error_message = "permissions_boundary_arn must be null when the roles carry no boundary"
  }
}

run "administrator_access_with_the_created_boundary" {
  command = plan

  variables {
    managed_policy_arns         = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    create_permissions_boundary = true
  }

  assert {
    condition     = aws_iam_policy.boundary[0].name == "github-actions-boundary" && aws_iam_policy.boundary[0].path == "/"
    error_message = "the boundary must be created as github-actions-boundary at path \"/\", the ARN the roles name"
  }

  assert {
    condition     = aws_iam_role.deploy[0].permissions_boundary == "arn:aws:iam::123456789012:policy/github-actions-boundary"
    error_message = "the deploy role must carry the boundary this component creates"
  }

  assert {
    condition     = aws_iam_role.plan[0].permissions_boundary == "arn:aws:iam::123456789012:policy/github-actions-boundary"
    error_message = "the plan role must carry the same boundary as the deploy role"
  }

  assert {
    condition     = output.permissions_boundary_arn == "arn:aws:iam::123456789012:policy/github-actions-boundary"
    error_message = "permissions_boundary_arn must report the boundary the roles carry"
  }

  assert {
    condition     = toset(keys(aws_iam_role_policy_attachment.deploy)) == toset(["arn:aws:iam::aws:policy/AdministratorAccess"])
    error_message = "the deploy role must carry exactly the managed policies the leaf lists"
  }

  assert {
    condition     = jsondecode(aws_iam_policy.boundary[0].policy) == jsondecode(data.aws_iam_policy_document.boundary[0].json)
    error_message = "the boundary policy must be created from the rendered boundary document these runs decode"
  }

  assert {
    condition     = aws_iam_role.deploy[0].tags["Component"] == "github-oidc" && aws_iam_role.plan[0].tags["Component"] == "github-oidc"
    error_message = "both roles must carry Component = github-oidc, the tag ProtectEveryGithubOidcRole keys on"
  }
}

run "boundary_allows_what_the_policies_grant_and_denies_the_rest" {
  command = plan

  variables {
    managed_policy_arns         = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    create_permissions_boundary = true
  }

  # The one Allow is everything, so AdministratorAccess on the deploy role and
  # ReadOnlyAccess on the plan role stay the effective grants.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Effect == "Allow"
    ]) == 1
    error_message = "the boundary must carry exactly one Allow statement"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Effect == "Allow" && flatten([s.Action]) == ["*"] && flatten([s.Resource]) == ["*"] && try(s.Condition, null) == null
    ]) == 1
    error_message = "the boundary's Allow must be an unconditional Action \"*\" on Resource \"*\": anything narrower silently caps AdministratorAccess or ReadOnlyAccess"
  }

  assert {
    condition = toset([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s.Sid if s.Effect == "Deny"
      ]) == toset([
      "ProtectThisBoundary",
      "ProtectTheseCiRoles",
      "ProtectEveryGithubOidcRole",
      "ProtectTheGithubOidcProvider",
      "DenyStrippingABoundary",
      "DenyLeavingThisBoundary",
      "DenyOrganizationAndAccountActions",
      "DenyDisablingSecurityServices",
    ])
    error_message = "the boundary must carry exactly the eight deny statements main.tf documents"
  }

  # 1. Its own definition.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Sid == "ProtectThisBoundary" && s.Effect == "Deny" &&
      flatten([s.Resource]) == ["arn:aws:iam::123456789012:policy/github-actions-boundary"] &&
      length(setsubtract(toset(["iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:DeletePolicy"]), toset(flatten([s.Action])))) == 0
    ]) == 1
    error_message = "ProtectThisBoundary must deny CreatePolicyVersion, SetDefaultPolicyVersion and DeletePolicy on the boundary's own ARN"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Sid == "ProtectTheseCiRoles" && s.Effect == "Deny" &&
      toset(flatten([s.Resource])) == toset([
        "arn:aws:iam::123456789012:role/github-actions-deploy",
        "arn:aws:iam::123456789012:role/github-actions-plan",
      ]) &&
      length(setsubtract(toset([
        "iam:DeleteRole", "iam:UpdateAssumeRolePolicy", "iam:AttachRolePolicy", "iam:PutRolePolicy",
        "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary", "iam:UntagRole",
      ]), toset(flatten([s.Action])))) == 0
    ]) == 1
    error_message = "ProtectTheseCiRoles must deny trust, policy, boundary, tag and delete writes on the deploy and plan roles by ARN"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Sid == "ProtectEveryGithubOidcRole" && s.Effect == "Deny" &&
      flatten([s.Resource]) == ["arn:aws:iam::123456789012:role/*"] &&
      flatten([try(s.Condition.StringEquals["aws:ResourceTag/Component"], [])]) == ["github-oidc"] &&
      contains(flatten([s.Action]), "iam:AttachRolePolicy") && contains(flatten([s.Action]), "iam:UpdateAssumeRolePolicy")
    ]) == 1
    error_message = "ProtectEveryGithubOidcRole must deny role writes on every role tagged Component = github-oidc (the ECR Public pull role on its own leaf included)"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Sid == "ProtectTheGithubOidcProvider" && s.Effect == "Deny" &&
      flatten([s.Resource]) == ["arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"] &&
      contains(flatten([s.Action]), "iam:DeleteOpenIDConnectProvider") &&
      contains(flatten([s.Action]), "iam:AddClientIDToOpenIDConnectProvider")
    ]) == 1
    error_message = "ProtectTheGithubOidcProvider must deny deleting or re-audiencing the GitHub OIDC provider the trusts name"
  }

  # 2. Shedding a ceiling.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Sid == "DenyStrippingABoundary" && s.Effect == "Deny" && flatten([s.Resource]) == ["*"] &&
      toset(flatten([s.Action])) == toset(["iam:DeleteRolePermissionsBoundary", "iam:DeleteUserPermissionsBoundary"])
    ]) == 1
    error_message = "DenyStrippingABoundary must deny both Delete*PermissionsBoundary verbs on every principal"
  }

  # 3. Stepping out.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Sid == "DenyLeavingThisBoundary" && s.Effect == "Deny" && flatten([s.Resource]) == ["*"] &&
      length(setsubtract(toset(["sts:AssumeRole", "iam:CreateUser", "iam:CreateLoginProfile", "iam:CreateAccessKey"]), toset(flatten([s.Action])))) == 0
    ]) == 1
    error_message = "DenyLeavingThisBoundary must deny sts:AssumeRole and minting an IAM user, password or access key"
  }

  # 4. Beyond the account, and its audit.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Sid == "DenyOrganizationAndAccountActions" && s.Effect == "Deny" && flatten([s.Resource]) == ["*"] &&
      toset(flatten([s.Action])) == toset(["organizations:*", "account:*"])
    ]) == 1
    error_message = "DenyOrganizationAndAccountActions must deny organizations:* and account:*"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Sid == "DenyDisablingSecurityServices" && s.Effect == "Deny" && flatten([s.Resource]) == ["*"] &&
      length(setsubtract(toset([
        "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "guardduty:DeleteDetector",
        "config:StopConfigurationRecorder", "securityhub:DisableSecurityHub", "access-analyzer:DeleteAnalyzer",
      ]), toset(flatten([s.Action])))) == 0
    ]) == 1
    error_message = "DenyDisablingSecurityServices must deny the audit-disabling verbs org-scp's DenyDisablingSecurity carries"
  }

  # No deny may reach the actions a deploy performs on everything else: role
  # creation and policy attachment stay unconditioned outside the protected set.
  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement :
      !(contains(flatten([s.Action]), "iam:CreateRole") || contains(flatten([s.Action]), "iam:PassRole"))
    ])
    error_message = "the boundary must not deny iam:CreateRole or iam:PassRole: the development deploy creates roles in a dozen components, most with no boundary input"
  }
}

run "boundary_protects_only_the_roles_this_leaf_creates" {
  command = plan

  variables {
    create_plan_role            = false
    create_permissions_boundary = true
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary[0].json).Statement : s
      if s.Sid == "ProtectTheseCiRoles" && flatten([s.Resource]) == ["arn:aws:iam::123456789012:role/github-actions-deploy"]
    ]) == 1
    error_message = "a leaf without a plan role must name only its deploy role in ProtectTheseCiRoles"
  }
}

run "administrator_access_under_a_supplied_boundary_accepted" {
  command = plan

  variables {
    managed_policy_arns      = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/estate-ci-boundary"
  }

  assert {
    condition     = length(aws_iam_policy.boundary) == 0
    error_message = "a supplied boundary must not create this component's own"
  }

  assert {
    condition = (aws_iam_role.deploy[0].permissions_boundary == "arn:aws:iam::123456789012:policy/estate-ci-boundary" &&
    aws_iam_role.plan[0].permissions_boundary == "arn:aws:iam::123456789012:policy/estate-ci-boundary")
    error_message = "a supplied permissions_boundary_arn must go on both roles"
  }
}

run "scoped_policies_without_a_boundary_accepted" {
  command = plan

  variables {
    managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"]
  }

  assert {
    condition     = aws_iam_role.deploy[0].permissions_boundary == null
    error_message = "the AdministratorAccess rule must not require a boundary for a scoped policy set"
  }
}

run "administrator_access_without_a_boundary_rejected" {
  command = plan

  variables {
    managed_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
  }

  expect_failures = [
    var.managed_policy_arns,
  ]
}

run "administrator_access_in_another_partition_without_a_boundary_rejected" {
  command = plan

  variables {
    managed_policy_arns = ["arn:aws-us-gov:iam::aws:policy/AdministratorAccess"]
  }

  expect_failures = [
    var.managed_policy_arns,
  ]
}

run "both_boundary_inputs_rejected" {
  command = plan

  variables {
    create_permissions_boundary = true
    permissions_boundary_arn    = "arn:aws:iam::123456789012:policy/estate-ci-boundary"
  }

  expect_failures = [
    var.create_permissions_boundary,
  ]
}

run "boundary_on_a_leaf_without_deploy_or_plan_role_rejected" {
  command = plan

  variables {
    create_deploy_role          = false
    create_plan_role            = false
    create_ecr_public_pull_role = true
    ecr_public_pull_repos       = ["eks-gitops"]
    create_permissions_boundary = true
  }

  expect_failures = [
    var.create_permissions_boundary,
  ]
}
