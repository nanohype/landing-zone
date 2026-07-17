include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/network.hcl"
  merge_strategy = "deep"
}

inputs = {
  nat_gateways         = 3
  enable_flow_logs     = true
  enable_vpc_endpoints = true
}
