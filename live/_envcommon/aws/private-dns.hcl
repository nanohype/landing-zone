terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/private-dns"
}

# private-dns is the participant side of the private-DNS topology: a workload account associates
# the Route53 Profile that the shared-dns owner (in the network account) RAM-shares to it with
# its cluster VPC. After association, every private zone the Profile carries resolves inside the
# VPC — the one cross-account DNS operation a workload account performs.
#
# vpc_id comes from the same-account network leaf (create or adopt — it re-exports vpc_id either
# way). profile_id is cross-account and env-specific, so it is wired in the leaf's own dependency
# block on the shared-dns owner leaf, not here.
dependency "network" {
  config_path = "../network"

  mock_outputs = {
    vpc_id = "vpc-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id = dependency.network.outputs.vpc_id
  team   = "platform"
}
