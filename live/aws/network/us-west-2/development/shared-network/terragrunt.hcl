include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/shared-network.hcl"
  merge_strategy = "deep"
}

inputs = {
  # A /16 shared VPC drawn from the org development IPAM sub-pool (10.0.0.0/12), discovered
  # by its org-ipam-development tag. Local-NAT egress (the additive TGW / centralized-egress
  # levers default off — flip them on per engagement, paired with an egress-network hub).
  ipam_netmask_length = 16
  nat_gateways        = 1

  # RAM-share private + public subnets to the workload-development account, which runs the
  # network component in adopt mode against them. Placeholder account ID — a real engagement
  # swaps in the real workload account.
  consumer_account_ids = ["111111111111"]
  share_public_subnets = true

  enable_vpc_endpoints = true
}
