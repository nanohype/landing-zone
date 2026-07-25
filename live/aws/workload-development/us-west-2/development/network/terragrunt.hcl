include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/network.hcl"
  merge_strategy = "deep"
}

# Create mode, by omission: components/aws/network defaults network_mode to "create",
# and the envcommon include already carries the minimal footprint baseline
# (enable_interface_endpoints = false; nat_gateways and enable_flow_logs are minimal
# at the module defaults). A development environment owns its own VPC and depends on
# nothing outside this account, which is what makes it installable from a standing
# start.
#
# The adopt-mode worked example lives at live/aws/reference-adopt/ — deliberately
# outside every workload account, because a workload environment that depends on
# another account's state cannot be brought up on its own. See the README there.

inputs = {}
