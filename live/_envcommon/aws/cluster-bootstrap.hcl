terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/cluster-bootstrap"
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    cluster_name                       = "mock-eks"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    network_mode       = "create"
    private_subnet_ids = ["subnet-1", "subnet-2", "subnet-3"]
    public_subnet_ids  = ["subnet-4", "subnet-5", "subnet-6"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  cluster_name                       = dependency.cluster.outputs.cluster_name
  cluster_endpoint                   = dependency.cluster.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.cluster.outputs.cluster_certificate_authority_data
  vpc_id                             = dependency.network.outputs.vpc_id

  # Mode + subnet IDs follow the paired network leaf. cluster-bootstrap publishes the
  # subnet IDs (onto the ArgoCD cluster Secret + the kube-system/network-config
  # ConfigMap) only in adopt mode — a create cluster's load balancer controllers
  # auto-discover subnets by the ELB role tags it stamps — so passing network's
  # outputs through unconditionally is safe: the component gates on network_mode.
  # Deriving it here means an adopt cluster needs only network_mode = adopt on its
  # network leaf, not a second knob kept in sync (mirrors how cluster derives
  # stamp_subnet_tags from the same output).
  network_mode       = dependency.network.outputs.network_mode
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  public_subnet_ids  = dependency.network.outputs.public_subnet_ids
}
