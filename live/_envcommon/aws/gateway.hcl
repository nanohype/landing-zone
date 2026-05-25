terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/gateway"
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
  cluster_sg_id     = dependency.cluster.outputs.cluster_security_group_id
  oidc_provider_arn = dependency.cluster.outputs.oidc_provider_arn
  oidc_issuer       = dependency.cluster.outputs.oidc_issuer
  team              = "platform"
}
