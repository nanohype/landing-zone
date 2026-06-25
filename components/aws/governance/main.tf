data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  tags = merge(var.tags, {
    Component = "governance"
    Team      = var.team
  })
}

module "tenant" {
  for_each = var.tenants
  source   = "./modules/tenant"

  environment   = var.environment
  region        = var.region
  account_id    = local.account_id
  tenant_id     = each.key
  tenant_config = each.value
  cluster_name  = var.cluster_name
  tags          = local.tags
}
