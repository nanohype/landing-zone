include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/github-oidc.hcl"
  merge_strategy = "deep"
}

# Apply ONCE per account (the OIDC provider is account-global). Run locally with
# admin/SSO creds; outputs deploy_role_arn for the AWS_ROLE_ARN / E2E_AWS_ROLE_ARN
# repo vars when/if the GitHub Actions CI path is adopted.
#
# Trust stays environment-gated deploys + tag pushes
# (allowed_subject_claims = ["environment:*", "ref:refs/tags/*"]). The e2e job
# declares `environment: e2e`, so its token presents
# repo:nanohype/landing-zone:environment:e2e and matches the first claim. Any CI
# job that needs this role from a NON-environment context on main — the scheduled
# drift job, the ci-push plan — takes the same route: give it a GitHub Environment.
# Adding "ref:refs/heads/main" here would work and is deliberately not done, because
# it hands every workflow on main a role that can provision and destroy EKS and IAM.
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
# This leaf sits under us-east-1 while the rest of workload-development is
# us-west-2. That is not an inconsistency to tidy up later: the OIDC provider and
# both roles are account-GLOBAL, so pinning them to a regional tree was always a
# claim the resources do not make. us-east-1 is also the only region the Ventures
# OU's `guardrail-region-lock` SCP permits, so it is the only region this leaf can
# be applied into today — but the merits argument stands on its own and survives
# that SCP changing.

# The account already has the GitHub Actions OIDC provider (AWS allows one per
# issuer), so this component references it rather than creating a second.
inputs = {
  github_repos         = ["landing-zone"]
  create_oidc_provider = false
}
