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
# Trust defaults to environment-gated deploys + tag pushes
# (allowed_subject_claims = ["environment:*", "ref:refs/tags/*"]). If the adopted CI
# assumes this role from a NON-environment context on main — the scheduled drift job,
# the e2e job (no job-level `environment:`), or the ci-push plan — add
# "ref:refs/heads/main" to allowed_subject_claims here, or gate those jobs behind a
# GitHub Environment.
inputs = {
  github_repos = ["landing-zone"]
}
