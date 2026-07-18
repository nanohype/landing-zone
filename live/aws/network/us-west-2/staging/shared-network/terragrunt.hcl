include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/shared-network.hcl"
  merge_strategy = "deep"
}

inputs = {
  # A /16 shared VPC drawn from the org staging IPAM sub-pool (10.16.0.0/12), discovered by
  # its org-ipam-staging tag. Local-NAT egress, one NAT gateway per zone (per-AZ HA — the
  # module supports a single shared NAT or one per AZ, not an in-between count).
  ipam_netmask_length = 16
  nat_gateways        = 3

  # RAM-share private + public subnets to the workload-staging account. Placeholder ID.
  consumer_account_ids = ["222222222222"]
  share_public_subnets = true

  enable_vpc_endpoints = true

  # Flow logs on: this shared VPC carries every adopting account's traffic, so it is
  # the owner's job to log it (an adopting spoke can't log a VPC it doesn't own).
  enable_flow_logs = true
}
