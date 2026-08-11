terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/tenant-substrate"
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    private_subnet_ids = ["subnet-1", "subnet-2", "subnet-3"]
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    cluster_security_group_id = "sg-mock"
    node_security_group_id    = "sg-mocknode"
    cluster_name              = "mock-eks"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  vpc_id             = dependency.network.outputs.vpc_id
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  cluster_sg_id      = dependency.cluster.outputs.cluster_security_group_id
  # The NODE security group, not the cluster one. Pods egress through the node's
  # ENI, so the node SG is the source address a datastore's ingress rule sees. The
  # cluster SG is attached to the control plane's ENIs and admits nothing a
  # workload sends — an RDS cluster allowing it accepts connections from nobody,
  # while every gate reports the substrate healthy.
  node_sg_id   = dependency.cluster.outputs.node_security_group_id
  cluster_name = dependency.cluster.outputs.cluster_name
  team         = "platform"

  # Rendered from the Platform CRs by the factory; empty until the first tenant
  # declares datastores.
  tenants = {}
}
