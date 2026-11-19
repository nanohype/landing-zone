terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/github-oidc"
}

locals {
  # The account directory the leaf sits in: live/aws/<account>/, where
  # account.hcl lives. Functions in an included config resolve from the leaf,
  # so this is the including leaf's account, not this file's directory.
  account_dir = dirname(find_in_parent_folders("account.hcl"))

  # Every environment the account holds, read from each env.hcl under it
  # (live/aws/<account>/<region>/<env>/env.hcl) — the same `environment` local
  # root.hcl injects into every leaf. The roles this component creates are
  # account-global, and one state bucket per account holds every environment's
  # state, so the plan role's trust is decided by what the ACCOUNT holds, not by
  # which environment directory the leaf happens to sit in: a github-oidc leaf
  # under network/us-east-1/development is in an account that also holds
  # production. github-oidc's plan_allowed_subject_claims validation reads this.
  account_environments = sort(distinct([
    for f in fileset(local.account_dir, "*/*/env.hcl") :
    read_terragrunt_config("${local.account_dir}/${f}").locals.environment
  ]))
}

inputs = {
  team                 = "platform"
  account_environments = local.account_environments
}
