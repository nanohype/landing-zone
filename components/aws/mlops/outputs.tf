output "tenants" {
  description = "Per-tenant MLOps resource map"
  value = {
    for tid, t in module.tenant : tid => {
      datasets_bucket_name        = t.datasets_bucket_name
      datasets_bucket_arn         = t.datasets_bucket_arn
      artifacts_bucket_name       = t.artifacts_bucket_name
      artifacts_bucket_arn        = t.artifacts_bucket_arn
      kms_key_arn                 = t.kms_key_arn
      experiments_table_name      = t.experiments_table_name
      experiments_table_arn       = t.experiments_table_arn
      model_registry_table_name   = t.model_registry_table_name
      model_registry_table_arn    = t.model_registry_table_arn
      training_queue_url          = t.training_queue_url
      training_queue_arn          = t.training_queue_arn
      training_dlq_url            = t.training_dlq_url
      training_dlq_arn            = t.training_dlq_arn
      ecr_repository_uri          = t.ecr_repository_uri
      ecr_repository_arn          = t.ecr_repository_arn
      training_worker_role_arn    = t.training_worker_role_arn
      model_registry_role_arn     = t.model_registry_role_arn
      mlops_api_role_arn          = t.mlops_api_role_arn
      namespace                   = t.namespace
      training_worker_policy_json = t.training_worker_policy_json
      model_registry_policy_json  = t.model_registry_policy_json
      mlops_api_policy_json       = t.mlops_api_policy_json
    }
  }
}
