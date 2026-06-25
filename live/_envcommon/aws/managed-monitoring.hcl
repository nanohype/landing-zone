terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/managed-monitoring"
}

locals {
  region_vars = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  env_vars    = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  region      = local.region_vars.locals.region
  environment = local.env_vars.locals.environment
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    cluster_name      = "mock-eks"
  }
}

inputs = {
  environment       = local.environment
  region            = local.region
  cluster_name      = dependency.cluster.outputs.cluster_name
  team              = "platform"
}
