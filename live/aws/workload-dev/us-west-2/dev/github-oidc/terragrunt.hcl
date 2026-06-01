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
inputs = {
  github_repos = ["landing-zone"]
}
