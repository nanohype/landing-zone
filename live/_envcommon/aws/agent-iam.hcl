terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/agent-iam"
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/mock"
    oidc_issuer       = "oidc.eks.us-west-2.amazonaws.com/id/MOCK"
    cluster_name      = "mock-eks"
  }
}

inputs = {
  oidc_provider_arn = dependency.cluster.outputs.oidc_provider_arn
  oidc_issuer       = dependency.cluster.outputs.oidc_issuer
  cluster_name      = dependency.cluster.outputs.cluster_name
  team              = "platform"
}
