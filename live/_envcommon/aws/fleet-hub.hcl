terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/fleet-hub"
}

# The hub IRSA role (eks-fleet-crossplane) trusts the hub cluster's OIDC provider,
# so fleet-hub depends on the cluster component's OIDC outputs. Apply order:
# network -> cluster -> cluster-bootstrap -> fleet-hub.
dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/MOCK"
    oidc_issuer       = "oidc.eks.us-west-2.amazonaws.com/id/MOCK"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  oidc_provider_arn = dependency.cluster.outputs.oidc_provider_arn
  oidc_issuer       = dependency.cluster.outputs.oidc_issuer
  team              = "platform"
}
