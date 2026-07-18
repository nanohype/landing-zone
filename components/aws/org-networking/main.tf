locals {
  tags = merge(var.tags, {
    Component = "org-networking"
    Team      = var.team
  })
}

################################################################################
# Transit Gateway
################################################################################

resource "aws_ec2_transit_gateway" "this" {
  #checkov:skip=CKV_AWS_331:auto-accept is intentional — attachments arrive only from RAM-shared org accounts (the TGW is shared over RAM to the org), so there is no cross-org attachment surface to gate.
  count = var.enable_transit_gateway ? 1 : 0

  amazon_side_asn                 = var.tgw_asn
  default_route_table_association = var.tgw_default_route_table_association ? "enable" : "disable"
  default_route_table_propagation = var.tgw_default_route_table_propagation ? "enable" : "disable"
  dns_support                     = "enable"
  auto_accept_shared_attachments  = "enable"

  tags = merge(local.tags, { Name = "org-transit-gateway" })
}

################################################################################
# RAM — Share Transit Gateway
################################################################################

resource "aws_ram_resource_share" "tgw" {
  count = var.enable_transit_gateway ? 1 : 0

  name                      = "org-transit-gateway"
  allow_external_principals = false
  tags                      = merge(local.tags, { Name = "org-transit-gateway-share" })
}

resource "aws_ram_resource_association" "tgw" {
  count = var.enable_transit_gateway ? 1 : 0

  resource_arn       = aws_ec2_transit_gateway.this[0].arn
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}

resource "aws_ram_principal_association" "tgw" {
  for_each = var.enable_transit_gateway ? toset(var.ram_principals) : toset([])

  principal          = each.value
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "tgw_id" {
  count = var.enable_transit_gateway ? 1 : 0

  name  = "/platform/${var.environment}/networking/tgw-id"
  type  = "String"
  value = aws_ec2_transit_gateway.this[0].id
  tags  = local.tags
}

resource "aws_ssm_parameter" "tgw_arn" {
  count = var.enable_transit_gateway ? 1 : 0

  name  = "/platform/${var.environment}/networking/tgw-arn"
  type  = "String"
  value = aws_ec2_transit_gateway.this[0].arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "ram_share_arn" {
  count = var.enable_transit_gateway ? 1 : 0

  name  = "/platform/${var.environment}/networking/ram-share-arn"
  type  = "String"
  value = aws_ram_resource_share.tgw[0].arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "ipam_pool_id" {
  count = var.enable_ipam ? 1 : 0

  name  = "/platform/${var.environment}/networking/ipam-pool-id"
  type  = "String"
  value = aws_vpc_ipam_pool.top_level[0].id
  tags  = local.tags
}

resource "aws_ssm_parameter" "resolver_rule_ids" {
  for_each = var.enable_resolver ? var.resolver_rules : {}

  name  = "/platform/${var.environment}/networking/resolver-rule-ids/${each.key}"
  type  = "String"
  value = aws_route53_resolver_rule.this[each.key].id
  tags  = local.tags
}
