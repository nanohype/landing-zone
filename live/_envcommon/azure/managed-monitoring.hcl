terraform {
  # `//` separator: copy the WHOLE repo-root into .terragrunt-cache, then run
  # tofu from `components/azure/managed-monitoring` within. Required because
  # the component references `../../../modules/azure/workload-identity`.
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/azure/managed-monitoring"
}

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  subscription_id = local.account_vars.locals.subscription_id
  tenant_id       = local.account_vars.locals.tenant_id
  location        = local.region_vars.locals.region
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
  tenant_id       = local.tenant_id
  location        = local.location
  cluster_name    = dependency.cluster.outputs.cluster_name
  oidc_issuer_url = dependency.cluster.outputs.oidc_issuer_url
  team            = "platform"
}
