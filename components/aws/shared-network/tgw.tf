# Transit gateway attachment + routing (when transit_gateway_id is set).
#
# The VPC module manages NAT and local routes; it does not manage TGW attachments or TGW
# routes — those are separate resources, added here. Two route additions on every private
# route table:
#   - 10.0.0.0/8 -> TGW, so the shared VPC reaches the rest of the org's address space
#     (other spokes, on-prem) through the transit gateway.
#   - 0.0.0.0/0 -> TGW, but only under centralized_egress, where there is no local NAT and
#     default egress leaves via a central egress VPC (egress-network) behind the TGW.

locals {
  tgw_enabled = var.transit_gateway_id != ""
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = local.tgw_enabled ? 1 : 0

  transit_gateway_id = var.transit_gateway_id
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets

  tags = merge(local.tags, {
    Name = "${var.environment}-shared-tgw-attachment"
  })
}

resource "aws_route" "tgw_intra_org" {
  count = local.tgw_enabled ? length(module.vpc.private_route_table_ids) : 0

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route" "tgw_default_egress" {
  count = local.tgw_enabled && var.centralized_egress ? length(module.vpc.private_route_table_ids) : 0

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
