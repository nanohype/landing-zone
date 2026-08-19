include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/network.hcl"
  merge_strategy = "deep"
}

inputs = {
  # One NAT gateway per zone (per-AZ HA egress). The module supports a single shared NAT (1)
  # or one per AZ (= max_azs); an in-between count is not expressible, so staging mirrors
  # production's per-AZ egress posture.
  nat_gateways               = 3
  enable_flow_logs           = true
  enable_interface_endpoints = true
}
