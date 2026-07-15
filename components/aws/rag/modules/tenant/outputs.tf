output "opensearch_endpoint" {
  description = "OpenSearch Serverless collection endpoint"
  value       = aws_opensearchserverless_collection.vectors.collection_endpoint
}

output "opensearch_collection_arn" {
  description = "OpenSearch Serverless collection ARN"
  value       = aws_opensearchserverless_collection.vectors.arn
}

output "document_bucket" {
  description = "S3 bucket name for RAG documents"
  value       = module.document_bucket.s3_bucket_id
}

output "conversations_table" {
  description = "DynamoDB conversations table name"
  value       = aws_dynamodb_table.conversations.name
}

output "irsa_arn" {
  description = "IAM role ARN for the bedrock-api IRSA"
  value       = module.bedrock_api_irsa.iam_role_arn
}

output "bedrock_api_policy_json" {
  description = "Rendered inline policy JSON for the bedrock-api role — surfaces the tenant's effective Bedrock model scope."
  value       = module.bedrock_api_irsa.role_policy_json
}
