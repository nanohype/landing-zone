include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/network.hcl"
  merge_strategy = "deep"
}

# ─── Org worked example: a spoke account in adopt mode ────────────────────────
# The org's canonical adopt-mode reference, so an engagement — or a day-0
# installer growing adopt support — has one concrete, CI-verified wiring to copy
# instead of inventing the shape.
#
# Shape: a consuming spoke account's network component runs in adopt mode, taking
# the VPC and subnets that the shared-network leaf in the network account owns and
# RAM-shares, rather than building its own. A real engagement changes the account
# id in this tree's account.hcl and the owner's consumer_account_ids; the
# dependency block and inputs below copy verbatim.
#
# This tree is not a deployable environment and deliberately is not under
# live/aws/workload-*/ — see README.md at the root of it for why, and for what has
# to exist on the owner side before any of this can be applied.

dependency "shared_network" {
  config_path = "../../../../network/us-west-2/development/shared-network"

  # mock_outputs feed credential-less `terragrunt render` (the CI evaluate job)
  # when the owner leaf has no readable state — same mechanism the cluster→network
  # dependency uses in _envcommon/aws/cluster.hcl. These mock only the *dependency's*
  # outputs; the network component's own adopt.tf runs real aws_vpc / aws_subnet /
  # aws_route_table lookups against these IDs, and those are genuine AWS API calls
  # that execute only under `terragrunt plan` with credentials — which CI green-skips
  # when AWS_ROLE_ARN is unset, so a real plan is never attempted against these mocks.
  mock_outputs = {
    vpc_id             = "vpc-mock"
    private_subnet_ids = ["subnet-mock-1", "subnet-mock-2", "subnet-mock-3"]
    public_subnet_ids  = ["subnet-mock-4", "subnet-mock-5", "subnet-mock-6"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  # adopt: participate in the shared VPC the sibling shared-network leaf owns,
  # instead of building one here. The adopt_* inputs come straight from that owner
  # leaf's outputs — a consuming account never hand-copies subnet IDs.
  network_mode             = "adopt"
  adopt_vpc_id             = dependency.shared_network.outputs.vpc_id
  adopt_private_subnet_ids = dependency.shared_network.outputs.private_subnet_ids
  adopt_public_subnet_ids  = dependency.shared_network.outputs.public_subnet_ids

  # No create-mode levers here: nat_gateways, enable_flow_logs, enable_interface_endpoints,
  # ipam_pool_id, transit_gateway_id, and centralized_egress are all owner-side
  # concerns the shared-network leaf runs. The last three hard-reject network_mode =
  # adopt in their variable validations; the rest are simply inert in adopt mode
  # (their resources are gated on create_mode), so an adopt leaf sets none of them.
}
