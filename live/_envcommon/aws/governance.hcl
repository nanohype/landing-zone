terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/governance"
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    cluster_security_group_id = "sg-mock"
    cluster_name              = "mock-eks"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  cluster_sg_id = dependency.cluster.outputs.cluster_security_group_id
  cluster_name  = dependency.cluster.outputs.cluster_name
  team          = "security"
}
