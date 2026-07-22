/**
 * Lakehouse substrate — per-tenant MSK, Glue catalog, Batch compute, and a
 * three-tier S3 data lake (raw / staging / curated).
 *
 * NO WORKLOAD CONSUMES THIS YET. Nothing reads the SSM parameters it
 * publishes, and there is no cluster-side chart for it. That is deliberate,
 * not an oversight: it is held for a lakehouse workload, and it is the one
 * component in this repo exempt from the rule that substrate without a
 * consumer gets deleted.
 *
 * The exemption is not open-ended. If no workload materializes, this goes the
 * way of the other unconsumed components — the test is whether something reads
 * `<env>-pipeline-<tenant>/*` out of SSM. Check before assuming it is load-bearing.
 */

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  tags = merge(var.tags, {
    Component = "pipeline"
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
  vpc_id          = var.vpc_id
  private_subnets = var.private_subnet_ids
  cluster_sg_id   = var.cluster_sg_id
  cluster_name    = var.cluster_name
  tags            = local.tags
}
