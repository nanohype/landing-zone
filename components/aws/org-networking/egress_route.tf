# Central-egress static default route (owner side).
#
# Attachment CIDR propagation gives the TGW default route table the per-VPC CIDR routes that
# let spokes reach each other, but it never creates a 0.0.0.0/0 route — so a spoke that flips
# centralized_egress (0.0.0.0/0 -> TGW) has nothing to forward internet-bound traffic to. The
# egress-network hub supplies that terminating VPC + NAT; this route is what actually steers
# spoke default egress at the hub's attachment.
#
# It lives here, in the TGW owner, by necessity: a TGW participant cannot create, modify, or
# delete the transit gateway's route tables or their routes (AWS reserves the route table
# APIs to the owner). The hub, running in the network-owner account as a participant, builds
# the attachment and publishes its ID; the owner points the static route at it via
# egress_tgw_attachment_id. Additive and off by default — no route exists until the hub's
# attachment ID is wired in.

resource "aws_ec2_transit_gateway_route" "egress_default" {
  count = var.enable_transit_gateway && var.egress_tgw_attachment_id != "" ? 1 : 0

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = var.egress_tgw_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this[0].association_default_route_table_id
}
