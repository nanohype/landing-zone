output "tenants" {
  description = "Per-tenant RAG infrastructure outputs"
  value = {
    for tenant_id, tenant in module.tenant : tenant_id => {
      opensearch_endpoint       = tenant.opensearch_endpoint
      opensearch_collection_arn = tenant.opensearch_collection_arn
      document_bucket           = tenant.document_bucket
      conversations_table       = tenant.conversations_table
      bedrock_api_role_arn      = tenant.bedrock_api_role_arn
      bedrock_api_policy_json   = tenant.bedrock_api_policy_json
    }
  }
}
