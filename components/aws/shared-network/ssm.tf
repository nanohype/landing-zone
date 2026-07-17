# Publish the shared-network facts to this account's OWN SSM under
# /platform/<env>/shared-network/*. These are for the owner account's own automation and
# audit; they are NOT cross-account readable, so they are not the hand-off channel to a
# consumer account (the consumer receives subnet IDs through its own adopt_* inputs and the
# README contract). Values are discovery metadata — VPC/subnet IDs, AZ IDs, the RAM share
# ARN — never secrets, so String / StringList is the correct type.

resource "aws_ssm_parameter" "vpc_id" {
  name  = "/platform/${var.environment}/shared-network/vpc-id"
  type  = "String"
  value = module.vpc.vpc_id
  tags  = local.tags
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name  = "/platform/${var.environment}/shared-network/vpc-cidr"
  type  = "String"
  value = module.vpc.vpc_cidr_block
  tags  = local.tags
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "/platform/${var.environment}/shared-network/private-subnet-ids"
  type  = "StringList"
  value = join(",", module.vpc.private_subnets)
  tags  = local.tags
}

resource "aws_ssm_parameter" "public_subnet_ids" {
  name  = "/platform/${var.environment}/shared-network/public-subnet-ids"
  type  = "StringList"
  value = join(",", module.vpc.public_subnets)
  tags  = local.tags
}

resource "aws_ssm_parameter" "private_subnet_az_ids" {
  name  = "/platform/${var.environment}/shared-network/private-subnet-az-ids"
  type  = "StringList"
  value = join(",", local.az_ids)
  tags  = local.tags
}

resource "aws_ssm_parameter" "ram_share_arn" {
  count = local.ram_enabled ? 1 : 0

  name  = "/platform/${var.environment}/shared-network/ram-share-arn"
  type  = "String"
  value = aws_ram_resource_share.subnets[0].arn
  tags  = local.tags
}
