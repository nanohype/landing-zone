terraform {
  # `//` separator: copy the WHOLE repo-root into .terragrunt-cache, then run
  # tofu from `components/azure/cluster-addons` within. Required because the
  # component references `../../../modules/azure/workload-identity`.
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/azure/cluster-addons"
}

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  subscription_id = local.account_vars.locals.subscription_id
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    cluster_name    = "mock-aks"
    oidc_issuer_url = "https://mock.oic.production-aks.azure.com/mock"
  }
}

inputs = {
  subscription_id = local.subscription_id
  cluster_name    = dependency.cluster.outputs.cluster_name
  oidc_issuer_url = dependency.cluster.outputs.oidc_issuer_url
  team            = "platform"
}
