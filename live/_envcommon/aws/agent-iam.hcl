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

# The secrets component's KMS key encrypts the model-artifacts + eval-reports
# buckets. Both are post-cluster fan-out components, so this edge just orders
# secrets before agent-iam on the core chain — agent-iam still applies before
# ArgoCD brings the operator up.
dependency "secrets" {
  config_path = "../secrets"
  mock_outputs = {
    kms_key_arn = "arn:aws:kms:us-west-2:123456789012:key/mock"
  }
}

inputs = {
  oidc_provider_arn = dependency.cluster.outputs.oidc_provider_arn
  oidc_issuer       = dependency.cluster.outputs.oidc_issuer
  cluster_name      = dependency.cluster.outputs.cluster_name
  data_kms_key_arn  = dependency.secrets.outputs.kms_key_arn
  team              = "platform"
}
