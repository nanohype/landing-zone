output "irsa_role_arn" {
  description = "IAM role ARN for the dispatch ServiceAccount. The eks-agent-platform operator reconciles this onto the chart's ServiceAccount's eks.amazonaws.com/role-arn annotation."
  value       = module.dispatch_irsa.iam_role_arn
}

output "aurora_cluster_endpoint" {
  description = "Aurora Postgres writer endpoint. Wired to the chart's DATABASE_URL composition."
  value       = module.aurora.cluster_endpoint
}

output "aurora_cluster_port" {
  description = "Aurora Postgres port."
  value       = module.aurora.cluster_port
}

output "aurora_database_name" {
  description = "Default database name."
  value       = "dispatch"
}

output "aurora_master_user_secret_arn" {
  description = "Secrets Manager ARN holding RDS master credentials. The chart's ExternalSecret resolves db-credentials at this name."
  value       = module.aurora.cluster_master_user_secret[0].secret_arn
}

output "voice_baseline_bucket_name" {
  description = "S3 bucket name for the immutable voice-baseline corpus. Wired to the chart's VOICE_BASELINE_BUCKET env."
  value       = aws_s3_bucket.voice_baseline.bucket
}

output "raw_aggregations_bucket_name" {
  description = "S3 bucket name for per-run aggregation snapshots. Wired to the chart's RAW_AGGREGATIONS_BUCKET env."
  value       = aws_s3_bucket.raw_aggregations.bucket
}

output "ses_identity_arn" {
  description = "SES v2 verified email identity ARN. The IRSA policy scopes ses:SendEmail to this."
  value       = aws_sesv2_email_identity.dispatch.arn
}

output "ses_configuration_set_name" {
  description = "SES configuration set name for per-send event tracking."
  value       = aws_sesv2_configuration_set.dispatch.configuration_set_name
}

output "ses_dkim_tokens" {
  description = "DKIM tokens emitted by SES. Publish as three CNAME records (<token>._domainkey.<domain>) in the sending domain's hosted zone before SES verifies the identity."
  value       = aws_sesv2_email_identity.dispatch.dkim_signing_attributes[0].tokens
}
