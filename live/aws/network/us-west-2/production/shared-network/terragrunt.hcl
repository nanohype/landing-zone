include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/shared-network.hcl"
  merge_strategy = "deep"
}

inputs = {
  # A /16 shared VPC drawn from the org production IPAM sub-pool (10.32.0.0/12), discovered
  # by its org-ipam-production tag. Local-NAT egress with one NAT gateway per zone.
  ipam_netmask_length = 16
  nat_gateways        = 3

  # RAM-share private + public subnets to the workload-production account. Placeholder ID.
  consumer_account_ids = ["333333333333"]
  share_public_subnets = true

  enable_vpc_endpoints = true
}
