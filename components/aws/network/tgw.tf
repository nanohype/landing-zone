# Transit gateway attachment + routing (create mode, when transit_gateway_id is set).
#
# The VPC module manages NAT and local routes; it does not manage TGW attachments or
# TGW routes — those are separate resources, added here. Two route additions:
#   - 10.0.0.0/8 -> TGW on every private route table, so the VPC reaches the rest of
#     the org's address space (other spokes, on-prem) through the transit gateway.
#   - 0.0.0.0/0 -> TGW on every private route table, but only under centralized_egress,
#     where there is no local NAT gateway and default egress leaves via a central
#     egress VPC behind the TGW.

locals {
  tgw_enabled = local.create_mode && var.transit_gateway_id != ""
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = local.tgw_enabled ? 1 : 0

  transit_gateway_id = var.transit_gateway_id
  vpc_id             = module.vpc[0].vpc_id
  subnet_ids         = module.vpc[0].private_subnets

  tags = merge(local.tags, {
    Name = "${var.environment}-tgw-attachment"
  })
}

resource "aws_route" "tgw_intra_org" {
  count = local.tgw_enabled ? length(local.resolved_private_route_table_ids) : 0

  route_table_id         = local.resolved_private_route_table_ids[count.index]
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route" "tgw_default_egress" {
  count = local.tgw_enabled && var.centralized_egress ? length(local.resolved_private_route_table_ids) : 0

  route_table_id         = local.resolved_private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
