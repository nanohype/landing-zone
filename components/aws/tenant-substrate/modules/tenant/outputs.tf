output "datastores" {
  description = "Per-datastore identifiers keyed by datastore name — kind, ARN, connection endpoint, and (relational only) the RDS-managed master-secret ARN. The operator publishes these into the Platform CR status so the tenant chart reads one predictable place."
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
