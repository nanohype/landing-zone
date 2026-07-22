terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/shared-dns"
}

# shared-dns is the owner side of the private-DNS topology: the network-owner account holds the
# private hosted zones and a Route53 Profile, and RAM-shares the Profile to the matching
# workload account (which associates it with its cluster VPC via the private-dns component). It
# sits alongside shared-network in the same network-owner account.
#
# The seed VPC is a creation requirement, not the resolution path: Route53 requires every
# private hosted zone to be associated with a same-account VPC at creation, so the zones are
# seeded with the sibling shared-network VPC. Fleet-wide resolution rides the Profile.
dependency "shared_network" {
  config_path = "../shared-network"

  # mock_outputs feed credential-less `terragrunt render` (the CI evaluate job) when the owner
  # leaf has no readable state — same mechanism the workload network→shared-network dependency
  # uses. A real plan (with credentials) reads the live output.
  mock_outputs = {
    vpc_id = "vpc-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  seed_vpc_id = dependency.shared_network.outputs.vpc_id
  team        = "platform"
}
