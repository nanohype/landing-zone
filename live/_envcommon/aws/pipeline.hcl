terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/pipeline"
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    private_subnet_ids = ["subnet-1", "subnet-2", "subnet-3"]
  }
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    cluster_security_group_id = "sg-mock"
    cluster_name = "mock-eks"
  }
}

inputs = {
  vpc_id             = dependency.network.outputs.vpc_id
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  cluster_sg_id      = dependency.cluster.outputs.cluster_security_group_id
  cluster_name = dependency.cluster.outputs.cluster_name
  team               = "data-platform"
}
