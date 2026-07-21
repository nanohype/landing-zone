output "tenant_outputs" {
  description = "Per-tenant infrastructure outputs"
  value = {
    for tenant_id, tenant in module.tenant : tenant_id => {
      aurora_endpoint        = tenant.aurora_endpoint
      aurora_port            = tenant.aurora_port
      s3_deepstorage         = tenant.s3_deepstorage
      s3_indexlogs           = tenant.s3_indexlogs
      s3_msq                 = tenant.s3_msq
      historical_role_arn    = tenant.historical_role_arn
      ingestion_role_arn     = tenant.ingestion_role_arn
      query_role_arn         = tenant.query_role_arn
      msk_bootstrap          = tenant.msk_bootstrap
      ingestion_policy_json  = tenant.ingestion_policy_json
      msk_client_policy_json = tenant.msk_client_policy_json
    }
  }
}
