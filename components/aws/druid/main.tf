data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  tags = merge(var.tags, {
    Component = "druid"
    Team      = var.team
  })
}

module "tenant" {
  for_each = var.tenants
  source   = "./modules/tenant"

  environment     = var.environment
  region          = var.region
  account_id      = local.account_id
  tenant_id       = each.key
  tenant_config   = each.value
  vpc_id          = var.network.vpc_id
  private_subnets = var.network.private_subnet_ids
  cluster_sg_id   = var.cluster_sg_id
  cluster_name    = var.cluster_name
  tags            = local.tags
}
