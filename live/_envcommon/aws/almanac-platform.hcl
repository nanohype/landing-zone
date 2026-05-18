/**
 * almanac-platform — env-shared inputs and dependency wiring.
 *
 * Per-env overrides go in
 * live/aws/<account>/<region>/<env>/almanac-platform/terragrunt.hcl.
 *
 * Single-tenant component, so this envcommon file is dependency wiring:
 * the cluster component supplies OIDC bits for the IRSA module's trust
 * policy; the network component supplies vpc_id + private subnets +
 * cluster security group for the Aurora + Redis ingress rules.
 */

dependency "network" {
  config_path = "${get_path_relative_to_include("live")}/../network"

  mock_outputs = {
    vpc_id             = "vpc-00000000"
    private_subnet_ids = ["subnet-aaaaaaaa", "subnet-bbbbbbbb", "subnet-cccccccc"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "cluster" {
  config_path = "${get_path_relative_to_include("live")}/../cluster"

  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/MOCK"
    oidc_issuer       = "oidc.eks.us-west-2.amazonaws.com/id/MOCK"
    cluster_sg_id     = "sg-00000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id             = dependency.network.outputs.vpc_id
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  oidc_provider_arn  = dependency.cluster.outputs.oidc_provider_arn
  oidc_issuer        = dependency.cluster.outputs.oidc_issuer
  cluster_sg_id      = dependency.cluster.outputs.cluster_sg_id
}
