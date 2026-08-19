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
      private_subnet_azs = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    cluster_security_group_id = "sg-mock"
    node_security_group_id    = "sg-node-mock"
    cluster_name              = "mock-eks"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  network       = dependency.network.outputs.network
  cluster_sg_id = dependency.cluster.outputs.cluster_security_group_id
  node_sg_id    = dependency.cluster.outputs.node_security_group_id
  cluster_name  = dependency.cluster.outputs.cluster_name
  team          = "data-platform"
}
