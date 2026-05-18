output "irsa_role_arn" {
  description = "IAM role ARN for the almanac ServiceAccount. The eks-agent-platform operator reconciles this onto the chart's ServiceAccount's eks.amazonaws.com/role-arn annotation."
  value       = module.almanac_irsa.iam_role_arn
}

output "tokens_table_name" {
  description = "DynamoDB table name for the per-user OAuth token store."
  value       = aws_dynamodb_table.tokens.name
}

output "audit_table_name" {
  description = "DynamoDB table name for the query/revocation audit log."
  value       = aws_dynamodb_table.audit.name
}

output "identity_cache_table_name" {
  description = "DynamoDB table name for the workforce-directory identity cache."
  value       = aws_dynamodb_table.identity_cache.name
}

output "audit_queue_url" {
  description = "SQS URL for the audit FIFO queue (producer side)."
  value       = aws_sqs_queue.audit.url
}

output "audit_dlq_url" {
  description = "SQS URL for the audit DLQ."
  value       = aws_sqs_queue.audit_dlq.url
}

output "audit_bucket_name" {
  description = "S3 bucket name for the long-term audit archive."
  value       = aws_s3_bucket.audit.bucket
}

output "kms_token_store_key_id" {
  description = "KMS key ID for per-user OAuth token envelope encryption. Wired to the chart's KMS_KEY_ID env."
  value       = aws_kms_key.token_store.key_id
}

output "redis_primary_endpoint" {
  description = "Primary write endpoint for the ElastiCache Redis replication group. Wired to the chart's REDIS_URL env (TLS — rediss://)."
  value       = aws_elasticache_replication_group.rate_limit.primary_endpoint_address
}

output "redis_port" {
  description = "ElastiCache Redis port."
  value       = aws_elasticache_replication_group.rate_limit.port
}

output "aurora_cluster_endpoint" {
  description = "Aurora Postgres writer endpoint. Wired to the chart's PGHOST env."
  value       = module.aurora.cluster_endpoint
}

output "aurora_cluster_port" {
  description = "Aurora Postgres port. Wired to the chart's PGPORT env."
  value       = module.aurora.cluster_port
}

output "aurora_master_user_secret_arn" {
  description = "Secrets Manager ARN holding RDS master credentials. Almanac points its db-credentials ExternalSecret at this name; the chart resolves username + password via External Secrets at pod start."
  value       = module.aurora.cluster_master_user_secret[0].secret_arn
}
