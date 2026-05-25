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
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id = "vpc-mock"
  }
}

inputs = {
  cluster_name                       = dependency.cluster.outputs.cluster_name
  cluster_endpoint                   = dependency.cluster.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.cluster.outputs.cluster_certificate_authority_data
  vpc_id                             = dependency.network.outputs.vpc_id
  team                               = "platform"
}
