/**
 * slack-knowledge-bot-platform — env-shared inputs and dependency wiring.
 *
 * Per-env overrides go in
 * live/aws/<account>/<region>/<env>/slack-knowledge-bot-platform/terragrunt.hcl.
 *
 * Single-tenant component, so this envcommon file is dependency wiring:
 * the cluster component supplies OIDC bits for the IRSA module's trust
 * policy; the network component supplies vpc_id + private subnets +
 * cluster security group for the Aurora + Redis ingress rules.
 */

terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/slack-knowledge-bot-platform"
}

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
    cluster_name  = "mock-eks"
    cluster_sg_id = "sg-00000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id             = dependency.network.outputs.vpc_id
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  cluster_name       = dependency.cluster.outputs.cluster_name
  cluster_sg_id      = dependency.cluster.outputs.cluster_sg_id
}
