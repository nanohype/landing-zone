/**
 * tenant-substrate — the generic per-tenant datastore substrate.
 *
 * A Platform CR declares the stateful stores its tenant needs (spec.datastores);
 * this component provisions them from that same declaration, so adding a tenant
 * is a declaration rather than a hand-written per-app component. Six
 * datastore kinds map to Aurora Serverless v2, DynamoDB, S3, SQS, ElastiCache,
 * and MSK Serverless.
 *
 * Boundary (per the tenant-substrate decision ledger): this component owns the
 * heavy stateful resources and their network security groups only. Identity —
 * the tenant IAM role and its scoped, generated policy — stays with the
 * eks-agent-platform operator, which never gains delete on a datastore. The
 * `tenants` map is rendered from the Platform CRs by the factory, not authored
 * by hand; wired by live/_envcommon/aws/tenant-substrate.hcl.
 */

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  tags = merge(var.tags, {
    Component = "tenant-substrate"
    Team      = var.team
  })
}

module "tenant" {
  for_each = var.tenants
  source   = "./modules/tenant"

  environment     = var.environment
  account_id      = local.account_id
  tenant_id       = each.key
  datastores      = each.value.datastores
  vpc_id          = var.vpc_id
  private_subnets = var.private_subnet_ids
  cluster_sg_id   = var.cluster_sg_id
  backup_policy   = var.backup_policy
  tags            = local.tags
}
