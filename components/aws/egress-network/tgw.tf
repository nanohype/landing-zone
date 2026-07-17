# Transit gateway attachment + the NAT return route.
#
# The egress hub attaches its NAT-facing private subnets to the org TGW. Traffic flows:
#
#   forward:  spoke (0.0.0.0/0 -> TGW) -> TGW default route table (static 0.0.0.0/0 route,
#             created by org-networking) -> this attachment -> private subnet -> NAT -> IGW
#   return:   internet -> IGW -> NAT -> public route table (spoke_supernet_cidr -> TGW) ->
#             TGW default route table (spoke CIDRs propagated) -> spoke attachment -> spoke
#
# NAT lives in the public subnets, so the return route toward the spokes goes on the PUBLIC
# route tables. The private (TGW-facing) subnets keep the module's default 0.0.0.0/0 -> NAT.

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets

  # transit_gateway_default_route_table_association / _propagation are deliberately left
  # unset (Optional + Computed) on this cross-account, RAM-shared TGW attachment. The AWS
  # provider gates the owner-side association/propagation call behind an owner-ID check: on a
  # shared TGW it skips that call entirely at Create — a participant has no permission to run
  # it — and then Read hardcodes both attributes back to true (the provider's own comment
  # notes drift detection on this field is intentionally impossible for a shared attachment).
  # So configuring either as false prevents nothing at create time; it instead pins a
  # permanent true -> false diff on every plan, and applying that diff hits the provider's
  # unconditioned Update path, which really does call the owner-only
  # DisassociateTransitGatewayRouteTable / DisableTransitGatewayRouteTablePropagation API from
  # this participant account and fails. Left unset, the attributes produce no diff. The
  # owner's TGW (org-networking: default association + propagation + auto_accept_shared_
  # attachments, all enabled) accepts this attachment and associates + propagates it into the
  # default route table from the owner side.

  # Stateful NAT sits behind this attachment. Appliance mode pins each flow to a single AZ so
  # the return path lands on the same NAT gateway that saw the forward path — without it,
  # cross-AZ asymmetry would break NAT's connection tracking and silently drop return traffic.
  appliance_mode_support = "enable"

  tags = merge(local.tags, {
    Name = "${var.environment}-egress-tgw-attachment"
  })
}

# Return route for NAT-translated replies: the NAT gateways sit in the public subnets, so the
# public route table needs a path back to the spokes' address space through the TGW.
# 0.0.0.0/0 already points at the internet gateway (the module's default), so this adds the
# more-specific spoke supernet route that wins for spoke-bound return traffic.
resource "aws_route" "spoke_return" {
  count = length(module.vpc.public_route_table_ids)

  route_table_id         = module.vpc.public_route_table_ids[count.index]
  destination_cidr_block = var.spoke_supernet_cidr
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
