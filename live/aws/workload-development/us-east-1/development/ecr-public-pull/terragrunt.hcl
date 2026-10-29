include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/github-oidc.hcl"
  merge_strategy = "deep"
}

# The ECR Public pull role, on its own state. It is the github-oidc component
# with the deploy and plan roles switched off, so this leaf's plan creates the
# pull role and its inline policy and nothing else, and an apply here can never
# create, change or destroy the roles the github-oidc leaf beside it manages.
# The two leaves also trust different repos: github-oidc trusts the repos that
# deploy this substrate, and this one trusts the repos whose CI pulls images and
# charts from public.ecr.aws.
#
# Apply once per account, with admin/SSO creds, like github-oidc: IAM is
# account-global. The ecr_public_pull_role_arn output goes in the
# ECR_PUBLIC_PULL_ROLE_ARN repo variable of each trusted repo; a workflow reads
# it to decide whether to log in, and pulls anonymously while it is unset.
#
# The subjects are the component default, repo:nanohype/eks-gitops:pull_request
# and repo:nanohype/eks-gitops:ref:refs/heads/main: the contexts eks-gitops'
# ci.yml runs in, on pull_request and on push to main. A workflow that adds
# another trigger whose token presents a different sub, such as a merge queue,
# adds that claim here.
inputs = {
  create_oidc_provider        = false
  create_deploy_role          = false
  create_plan_role            = false
  create_ecr_public_pull_role = true
  ecr_public_pull_repos       = ["eks-gitops"]
}
