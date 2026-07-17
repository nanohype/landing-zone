terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/cluster"
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    private_subnet_ids = ["subnet-1", "subnet-2", "subnet-3"]
    public_subnet_ids  = ["subnet-4", "subnet-5", "subnet-6"]
    network_mode       = "create"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id             = dependency.network.outputs.vpc_id
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  public_subnet_ids  = dependency.network.outputs.public_subnet_ids

  # Subnet-ownership tagging follows the paired network leaf's mode: the cluster stamps
  # kubernetes.io/cluster/<cluster> on its subnets in create mode, but a participant can't
  # tag a foreign-owned (RAM-shared) subnet in adopt mode — there the network owner
  # (shared-network) owns tagging. Deriving it here means an adopt cluster needs only
  # network_mode = adopt on its network leaf, not a second, manually-kept-in-sync knob on
  # cluster (mirrors the fleet/aws/cluster-stack path, which derives it the same way).
  stamp_subnet_tags = dependency.network.outputs.network_mode == "create"

  team = "platform"
}
