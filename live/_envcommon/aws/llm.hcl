terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/llm"
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
    oidc_provider_arn         = "arn:aws:iam::123456789012:oidc-provider/mock"
    oidc_issuer               = "oidc.eks.us-west-2.amazonaws.com/id/MOCK"
  }
}

inputs = {
  vpc_id             = dependency.network.outputs.vpc_id
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  cluster_sg_id      = dependency.cluster.outputs.cluster_security_group_id
  oidc_provider_arn  = dependency.cluster.outputs.oidc_provider_arn
  oidc_issuer        = dependency.cluster.outputs.oidc_issuer
  team               = "ml-platform"
}
