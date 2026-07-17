output "raw_bucket" {
  description = "Raw data lake S3 bucket name"
  value       = module.raw_bucket.s3_bucket_id
}

output "staging_bucket" {
  description = "Staging data lake S3 bucket name"
  value       = module.staging_bucket.s3_bucket_id
}

output "curated_bucket" {
  description = "Curated data lake S3 bucket name"
  value       = module.curated_bucket.s3_bucket_id
}

output "msk_arn" {
  description = "MSK Serverless cluster ARN (null if disabled)"
  value       = var.tenant_config.msk_enabled ? aws_msk_serverless_cluster.this[0].arn : null
}

output "batch_queue_arn" {
  description = "AWS Batch job queue ARN (null if disabled)"
  value       = var.tenant_config.batch_enabled ? aws_batch_job_queue.this[0].arn : null
}

output "glue_database" {
  description = "Glue catalog database name"
  value       = aws_glue_catalog_database.this.name
}

output "connector_policy_json" {
  description = "Rendered inline IAM policy JSON for the connector role (null if no statements). Lets tests assert the kafka-cluster scoping."
  value       = module.connector_irsa.role_policy_json
}
