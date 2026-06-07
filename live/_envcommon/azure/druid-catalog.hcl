terraform {
  # `//` separator: copy the WHOLE repo-root into .terragrunt-cache, then run
  # tofu from `components/azure/druid-catalog` within. Required because the
  # component references `../../../modules/azure/workload-identity`.
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/azure/druid-catalog"
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

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    private_subnet_ids = ["/subscriptions/mock/resourceGroups/mock/providers/Microsoft.Network/virtualNetworks/mock/subnets/private-0"]
  }
}

dependency "secrets" {
  config_path = "../secrets"
  mock_outputs = {
    key_vault_id = "/subscriptions/mock/resourceGroups/mock/providers/Microsoft.KeyVault/vaults/mock"
  }
}

inputs = {
  subscription_id   = local.subscription_id
  cluster_name      = dependency.cluster.outputs.cluster_name
  oidc_issuer_url   = dependency.cluster.outputs.oidc_issuer_url
  private_subnet_id = dependency.network.outputs.private_subnet_ids[0]
  key_vault_id      = dependency.secrets.outputs.key_vault_id
  team              = "analytics"
}
