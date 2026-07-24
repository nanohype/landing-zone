terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/pipeline"
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    network = {
      vpc_id             = "vpc-mock"
      ownership_mode     = "create"
      private_subnet_ids = ["subnet-1", "subnet-2", "subnet-3"]
      private_subnet_azs = ["us-west-2a", "us-west-2b", "us-west-2c"]
    }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    cluster_security_group_id = "sg-mock"
    cluster_name              = "mock-eks"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  network       = dependency.network.outputs.network
  cluster_sg_id = dependency.cluster.outputs.cluster_security_group_id
  cluster_name  = dependency.cluster.outputs.cluster_name
  team          = "data-platform"
}
