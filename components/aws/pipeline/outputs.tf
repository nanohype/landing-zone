output "tenant_outputs" {
  description = "Per-tenant pipeline infrastructure outputs"
  value = {
    for tenant_id, tenant in module.tenant : tenant_id => {
      raw_bucket            = tenant.raw_bucket
      staging_bucket        = tenant.staging_bucket
      curated_bucket        = tenant.curated_bucket
      msk_arn               = tenant.msk_arn
      batch_queue_arn       = tenant.batch_queue_arn
      glue_database         = tenant.glue_database
      connector_policy_json = tenant.connector_policy_json
    }
  }
}
