terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/observability"
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    cluster_name = "mock-eks"
  }
}

inputs = {
  cluster_name = dependency.cluster.outputs.cluster_name
  team         = "sre"
}
