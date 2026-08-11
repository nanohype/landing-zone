output "datastores" {
  description = "Per-datastore identifiers keyed by datastore name — kind, ARN, connection endpoint, secret ARN where one exists (relational master secret, cache AUTH token), and database name for kind=relational. The parent publishes relational secret ARNs to SSM for the operator; cache AUTH secrets are tenant Secrets Manager entries the app reaches via directSecretReads."
  value = merge(
    # `database` is published because it is composed here and knowable nowhere
    # else. An endpoint and a credential are not enough to open a connection —
    # the DSN also needs the database, this module names it `app_<datastore>`,
    # and a consumer that cannot read the name has to either re-derive the rule
    # (a second copy that drifts the first time this line changes) or guess. A
    # wrong guess connects and authenticates before failing on `database "x"
    # does not exist`, which reads like a broken app rather than a broken name.
    #
    # Null on every other kind rather than absent: merge() unifies these object
    # types, so the attribute set has to match across all six branches.
    { for k, m in module.relational : k => {
      kind       = "relational"
      arn        = m.cluster_arn
      endpoint   = m.cluster_endpoint
      secret_arn = try(m.cluster_master_user_secret[0].secret_arn, null)
      database   = m.cluster_database_name
    } },
    { for k, r in aws_dynamodb_table.key_value : k => {
      kind       = "keyValue"
      arn        = r.arn
      endpoint   = r.id
      secret_arn = null
      database   = null
    } },
    { for k, r in aws_s3_bucket.object_store : k => {
      kind       = "objectStore"
      arn        = r.arn
      endpoint   = r.bucket
      secret_arn = null
      database   = null
    } },
    { for k, r in aws_sqs_queue.queue : k => {
      kind       = "queue"
      arn        = r.arn
      endpoint   = r.url
      secret_arn = null
      database   = null
    } },
    { for k, r in aws_elasticache_replication_group.cache : k => {
      kind     = "cache"
      arn      = r.arn
      endpoint = r.primary_endpoint_address
      # AUTH token secret — transit encryption alone is not a credential.
      secret_arn = aws_secretsmanager_secret.cache_auth[k].arn
      database   = null
    } },
    { for k, r in aws_msk_serverless_cluster.stream : k => {
      kind       = "stream"
      arn        = r.arn
      endpoint   = r.cluster_name
      secret_arn = null
      database   = null
    } },
  )
}

output "kms_key_arn" {
  description = "ARN of the tenant's own customer-managed key. The parent component publishes it to SSM, where the operator reads it to scope the tenant role's KMS grant — application envelope encryption (GenerateDataKey/Decrypt) and the RDS-managed master secret both resolve to this one key."
  value       = aws_kms_key.tenant.arn
}
