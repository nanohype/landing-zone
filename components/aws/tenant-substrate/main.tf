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

# The operator scopes each tenant's Secrets Manager grant to exactly the secret
# its own Aurora cluster owns, and it cannot compose that ARN itself: RDS derives
# the managed secret's name from the cluster's AWS-generated resource id
# (rds!cluster-<id>), so the <env>-<tenant>-<datastore> convention every other
# grant is scoped by has nothing to bind to here. Without a published ARN the
# only available scope is the shared rds!cluster-* prefix, which every Aurora
# cluster in the account matches — no scope at all, and one tenant holding every
# other tenant's master credentials.
#
# The subtree is keyed on the full cluster name, so co-located sibling clusters
# stay isolated and the path sits inside the /eks-agent-platform/<cluster>/ tree
# the operator already sweeps. That sweep decodes the keys it knows and ignores
# the rest, so these parameters are additive to it.
locals {
  # Keys come from the declaration rather than from the module's output: the
  # secret ARN is unknown until apply, and a for_each whose keys depend on an
  # unknown cannot be planned. The declaration is static, so the key set is too.
  relational_secret_arns = {
    for entry in flatten([
      for tenant, t in var.tenants : [
        for d in t.datastores : {
          key = "${tenant}/${d.name}"
          arn = module.tenant[tenant].datastores[d.name].secret_arn
        } if d.kind == "relational"
      ]
    ]) : entry.key => entry.arn
  }
}

# The tenant's own key, on the same contract and for the same reason: the ARN is
# AWS-generated, so the operator cannot compose it and has nothing to scope a KMS
# grant to without it. One parameter per tenant, whether or not that tenant
# declares a datastore — the key backs application envelope encryption, which is
# independent of the datastore vocabulary.
resource "aws_ssm_parameter" "tenant_kms_key_arn" {
  for_each = var.tenants

  name        = "/eks-agent-platform/${var.cluster_name}/tenant-substrate/${each.key}/kms_key_arn"
  description = "ARN of this tenant's customer-managed key. Read by the eks-agent-platform operator to scope the tenant role's KMS grant to the tenant's own key."
  type        = "String"
  value       = module.tenant[each.key].kms_key_arn
  tags        = local.tags
}

resource "aws_ssm_parameter" "master_secret_arn" {
  for_each = local.relational_secret_arns

  name        = "/eks-agent-platform/${var.cluster_name}/tenant-substrate/${each.key}/master_secret_arn"
  description = "ARN of the RDS-managed master-user secret for this tenant's Aurora cluster. Read by the eks-agent-platform operator to scope the tenant role's Secrets Manager grant to this one secret."
  type        = "String"
  value       = each.value
  tags        = local.tags
}
