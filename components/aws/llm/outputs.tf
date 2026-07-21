output "tenant_outputs" {
  description = "Per-tenant LLM infrastructure outputs"
  value = {
    for tenant_id, tenant in module.tenant : tenant_id => {
      model_bucket_name            = tenant.model_bucket_name
      model_bucket_arn             = tenant.model_bucket_arn
      model_kms_key_arn            = tenant.model_kms_key_arn
      efs_filesystem_id            = tenant.efs_filesystem_id
      efs_access_point_id          = tenant.efs_access_point_id
      sqs_inference_queue_url      = tenant.sqs_inference_queue_url
      sqs_inference_queue_arn      = tenant.sqs_inference_queue_arn
      sqs_inference_dlq_url        = tenant.sqs_inference_dlq_url
      dynamodb_inference_table     = tenant.dynamodb_inference_table
      ecr_repository_uri           = tenant.ecr_repository_uri
      inference_server_role_arn    = tenant.inference_server_role_arn
      api_gateway_role_arn         = tenant.api_gateway_role_arn
      inference_server_policy_json = tenant.inference_server_policy_json
      api_gateway_policy_json      = tenant.api_gateway_policy_json
    }
  }
}
