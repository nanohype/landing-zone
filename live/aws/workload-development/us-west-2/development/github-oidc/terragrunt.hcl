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
# The account already has the GitHub Actions OIDC provider (AWS allows one per
# issuer), so this component references it rather than creating a second.
inputs = {
  github_repos         = ["landing-zone"]
  create_oidc_provider = false
}
