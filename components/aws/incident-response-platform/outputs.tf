output "app_access_policy_arn" {
  description = "Managed policy carrying incident-response's substrate grants. Reference it from Platform.spec.identity.extraPolicyArns; the eks-agent-platform operator attaches it to the tenant role."
  value       = module.platform_app.app_access_policy_arn
}

output "tenant_role_arn" {
  description = "Operator-reconciled tenant role the chart's ServiceAccount is bound to via the EKS Pod Identity association."
  value       = module.platform_app.tenant_role_arn
}

output "incidents_table_name" {
  description = "DynamoDB table name for incidents. Wired to the chart's INCIDENTS_TABLE_NAME env via tenantInfra."
  value       = aws_dynamodb_table.incidents.name
}

output "audit_table_name" {
  description = "DynamoDB table name for the audit log."
  value       = aws_dynamodb_table.audit.name
}

output "identity_cache_table_name" {
  description = "DynamoDB table name for the workforce-directory identity cache."
  value       = aws_dynamodb_table.identity_cache.name
}

output "incident_events_queue_url" {
  description = "SQS URL for the incident-events FIFO queue (webhook → processor)."
  value       = aws_sqs_queue.incident_events.url
}

output "nudge_events_queue_url" {
  description = "SQS URL for the nudge-events FIFO queue (Scheduler → processor)."
  value       = aws_sqs_queue.nudge_events.url
}

output "nudge_events_queue_arn" {
  description = "SQS ARN for nudge-events. Used by EventBridge Scheduler as the target."
  value       = aws_sqs_queue.nudge_events.arn
}

output "sla_check_queue_url" {
  description = "SQS URL for the sla-check FIFO queue."
  value       = aws_sqs_queue.sla_check.url
}

output "scheduler_role_arn" {
  description = "IAM role ARN that EventBridge Scheduler assumes when firing a nudge target. Wired to the chart's SCHEDULER_ROLE_ARN env."
  value       = aws_iam_role.schedule_role.arn
}

output "scheduler_group_name" {
  description = "EventBridge Scheduler group name incident-response's processor creates per-incident schedules under."
  value       = aws_scheduler_schedule_group.nudges.name
}

output "audit_bucket_name" {
  description = "S3 bucket name for the long-term audit archive."
  value       = aws_s3_bucket.audit.bucket
}
