terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/egress-network"
}

# egress-network is the central-egress hub — the receiving end of the centralized_egress
# lever. One hub per transit gateway (the org runs a single TGW), so it is instantiated once,
# in the network-owner account, under the hub slot. It attaches a small dedicated-CIDR VPC
# (NAT + TGW attachment) to the org TGW; the static 0.0.0.0/0 route that steers spoke egress
# at it is created by org-networking (the TGW owner) via egress_tgw_attachment_id, since a
# TGW participant cannot write the owner's route tables. No dependency block: the TGW arrives
# over RAM, not through this repo's state, and the owner-side route wiring is a manual
# cross-account activation step (see the component README).
inputs = {
  team = "platform"
}
