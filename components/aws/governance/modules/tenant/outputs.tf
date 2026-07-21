output "audit_bucket_name" {
  description = "Audit S3 bucket name"
  value       = module.audit_bucket.s3_bucket_id
}

output "audit_bucket_arn" {
  description = "Audit S3 bucket ARN"
  value       = module.audit_bucket.s3_bucket_arn
}

output "audit_kms_key_arn" {
  description = "Audit KMS key ARN"
  value       = aws_kms_key.audit.arn
}

output "guardrail_bucket_name" {
  description = "Guardrail S3 bucket name"
  value       = module.guardrail_bucket.s3_bucket_id
}

output "guardrail_bucket_arn" {
  description = "Guardrail S3 bucket ARN"
  value       = module.guardrail_bucket.s3_bucket_arn
}

output "audit_table_name" {
  description = "Audit DynamoDB table name"
  value       = aws_dynamodb_table.audit.name
}

output "audit_table_arn" {
  description = "Audit DynamoDB table ARN"
  value       = aws_dynamodb_table.audit.arn
}

output "cost_table_name" {
  description = "Cost DynamoDB table name"
  value       = aws_dynamodb_table.cost.name
}

output "cost_table_arn" {
  description = "Cost DynamoDB table ARN"
  value       = aws_dynamodb_table.cost.arn
}

output "event_bus_name" {
  description = "EventBridge bus name (null if disabled)"
  value       = var.tenant_config.event_bridge_enabled ? aws_cloudwatch_event_bus.this[0].name : null
}

output "event_bus_arn" {
  description = "EventBridge bus ARN (null if disabled)"
  value       = var.tenant_config.event_bridge_enabled ? aws_cloudwatch_event_bus.this[0].arn : null
}

output "audit_writer_role_arn" {
  description = "Pod Identity role ARN for the audit-writer service account"
  value       = module.audit_writer_irsa.iam_role_arn
}

output "governance_api_role_arn" {
  description = "Pod Identity role ARN for the governance-api service account"
  value       = module.governance_api_irsa.iam_role_arn
}

output "namespace" {
  description = "Kubernetes namespace for this tenant's governance workloads"
  value       = local.namespace
}
