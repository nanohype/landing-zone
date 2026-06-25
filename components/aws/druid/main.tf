locals {
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
  tenant_id       = each.key
  tenant_config   = each.value
  vpc_id          = var.vpc_id
  private_subnets = var.private_subnet_ids
  cluster_sg_id   = var.cluster_sg_id
  cluster_name    = var.cluster_name
  tags            = local.tags
}
