include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/egress-network.hcl"
  merge_strategy = "deep"
}

inputs = {
  # A dedicated /24 in carrier-grade NAT space (100.64.0.0/10) — outside the org workload
  # supernet (10.0.0.0/8), so it never overlaps a spoke drawn from the org IPAM pools.
  egress_vpc_cidr = "100.64.0.0/24"

  # Per-AZ NAT: the hub carries every environment's egress including production, so it runs
  # one NAT gateway per zone for HA (the module supports a single shared NAT or one per AZ,
  # not an in-between count).
  nat_gateways = 3

  # The org transit gateway, owned by org-networking (management account) and RAM-shared to
  # this network-owner account. Example id — a real engagement swaps in the real tgw-… . The
  # static 0.0.0.0/0 route that steers spokes at this hub is wired on the owner side, by
  # setting org-networking's egress_tgw_attachment_id to this component's tgw_attachment_id
  # output (see the component README).
  transit_gateway_id = "tgw-0a1b2c3d4e5f60789"

  # Flow logs on: this hub is the single egress chokepoint for every environment's
  # spoke traffic, so its flow logs are the highest-value network visibility in the org.
  enable_flow_logs = true
}
