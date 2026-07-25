output "datastores" {
  description = "Per-datastore identifiers keyed by datastore name — kind, ARN, connection endpoint, and (relational only) the RDS-managed master-secret ARN. The parent component publishes the relational secret ARNs to SSM, where the operator reads them to scope each tenant's Secrets Manager grant."
  value = merge(
    { for k, m in module.relational : k => {
      kind       = "relational"
      arn        = m.cluster_arn
      endpoint   = m.cluster_endpoint
      secret_arn = try(m.cluster_master_user_secret[0].secret_arn, null)
    } },
    { for k, r in aws_dynamodb_table.key_value : k => {
      kind       = "keyValue"
      arn        = r.arn
      endpoint   = r.id
      secret_arn = null
    } },
    { for k, r in aws_s3_bucket.object_store : k => {
      kind       = "objectStore"
      arn        = r.arn
      endpoint   = r.bucket
      secret_arn = null
    } },
    { for k, r in aws_sqs_queue.queue : k => {
      kind       = "queue"
      arn        = r.arn
      endpoint   = r.url
      secret_arn = null
    } },
    { for k, r in aws_elasticache_replication_group.cache : k => {
      kind       = "cache"
      arn        = r.arn
      endpoint   = r.primary_endpoint_address
      secret_arn = null
    } },
    { for k, r in aws_msk_serverless_cluster.stream : k => {
      kind       = "stream"
      arn        = r.arn
      endpoint   = r.cluster_name
      secret_arn = null
    } },
  )
}

output "kms_key_arn" {
  description = "ARN of the tenant's own customer-managed key. The parent component publishes it to SSM, where the operator reads it to scope the tenant role's KMS grant — application envelope encryption (GenerateDataKey/Decrypt) and the RDS-managed master secret both resolve to this one key."
  value       = aws_kms_key.tenant.arn
}
