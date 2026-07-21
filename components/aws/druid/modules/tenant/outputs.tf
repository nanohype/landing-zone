output "aurora_endpoint" {
  description = "Aurora cluster endpoint"
  value       = module.aurora.cluster_endpoint
}

output "aurora_port" {
  description = "Aurora cluster port"
  value       = module.aurora.cluster_port
}

output "s3_deepstorage" {
  description = "Deep storage S3 bucket name"
  value       = module.deepstorage_bucket.s3_bucket_id
}

output "s3_indexlogs" {
  description = "Index logs S3 bucket name"
  value       = module.indexlogs_bucket.s3_bucket_id
}

output "s3_msq" {
  description = "MSQ results S3 bucket name"
  value       = module.msq_bucket.s3_bucket_id
}

output "historical_role_arn" {
  description = "Pod Identity role ARN for historical nodes"
  value       = module.historical_irsa.iam_role_arn
}

output "ingestion_role_arn" {
  description = "Pod Identity role ARN for ingestion nodes"
  value       = module.ingestion_irsa.iam_role_arn
}

output "query_role_arn" {
  description = "Pod Identity role ARN for query nodes"
  value       = module.query_irsa.iam_role_arn
}

output "msk_bootstrap" {
  description = "MSK bootstrap servers (if enabled)"
  value       = var.tenant_config.msk_enabled ? aws_msk_serverless_cluster.this[0].arn : null
}

output "ingestion_policy_json" {
  description = "Rendered inline IAM policy JSON for the ingestion role. Lets tests assert the kafka-cluster scoping."
  value       = module.ingestion_irsa.role_policy_json
}

output "msk_client_policy_json" {
  description = "Rendered inline IAM policy JSON for the MSK client role (null when msk disabled)."
  value       = try(module.msk_client_irsa[0].role_policy_json, null)
}
