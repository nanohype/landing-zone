include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/network.hcl"
  merge_strategy = "deep"
}

inputs = {
  nat_gateways         = 1
  enable_flow_logs     = false
  enable_vpc_endpoints = true
}
