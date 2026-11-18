include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/github-oidc.hcl"
  merge_strategy = "deep"
}

# Apply ONCE per account (the OIDC provider is account-global). Run locally with
# admin/SSO creds when/if the GitHub Actions CI path is adopted. Outputs:
#   - deploy_role_arn: on the `development` GitHub Environment, as the role
#     variable deploy.yml/destroy.yml read, and as E2E_AWS_ROLE_ARN for e2e.yml.
#   - plan_role_arn: the repository-level AWS_ROLE_ARN (see THE PLAN ROLE below).
#
# Trust is narrowed from the component default (all four workload environments,
# the union across accounts) to the environments that deploy into THIS account:
# `development` (deploy.yml/destroy.yml) and `e2e` (e2e.yml, whose job declares
# `environment: e2e`, so its token presents
# repo:nanohype/landing-zone:environment:e2e). Staging and production deploy
# into their own accounts with their own github-oidc leaf; trusting them here
# would only let a staging/production job reach the development account's role.
#
# The component validates every claim as an exact "environment:<name>": no
# wildcard (GitHub creates an unprotected environment the first time a workflow
# names one, so "environment:dev*" would admit any "devx" a branch invents), no
# pull_request or ref: claim, and never "environment:plan" (ci.yml's PR plan job
# and drift.yml declare it). The trust names environments, not refs: a job that
# declares `environment: development` presents the same sub from any branch, so
# the `development` and `e2e` environments need a deployment-branch policy in repo
# settings (and `e2e` required reviewers) before any policy is attached here. A
# CI job that needs this role from a non-environment context takes the same
# route: give it its own protected environment and add that claim. Adding
# "ref:refs/heads/main" is refused by the validation, because it would hand every
# workflow on main a role that can provision and destroy EKS and IAM.
#
# THE PLAN ROLE is separate and read-only. The CI plan matrix runs on
# `pull_request`, which the deploy role above must never trust — so it gets its
# own role (github-actions-plan, ReadOnlyAccess) trusted from
# repo:nanohype/landing-zone:environment:plan. That is the same environment route
# this comment prescribes, applied rather than described: ci.yml's plan job
# declares `environment: plan`, so its token presents the environment claim and
# never a branch or pull_request one. Adding required reviewers to the `plan`
# environment in repo settings gates it on a human; the trust scoping holds either
# way. plan_role_arn is what goes in the AWS_ROLE_ARN repo variable — NOT
# deploy_role_arn.
#
# This leaf moved to us-east-1 before the rest of the estate followed, and the
# reason it moved first is worth keeping: the OIDC provider and both roles are
# account-GLOBAL, so pinning them to a regional tree was always a claim the
# resources do not make. That argument stands on its own and survives the SCP
# changing — which matters, because the estate-wide move that came after it was
# driven by the Ventures OU's `guardrail-region-lock`, a different reason that
# could be repealed.

# The account already has the GitHub Actions OIDC provider (AWS allows one per
# issuer), so this component references it rather than creating a second.
inputs = {
  github_repos           = ["landing-zone"]
  allowed_subject_claims = ["environment:development", "environment:e2e"]
  create_oidc_provider   = false
}
