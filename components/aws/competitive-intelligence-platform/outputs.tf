output "app_access_policy_arn" {
  description = "Managed policy carrying competitive-intelligence's substrate grants. Reference it from Platform.spec.identity.extraPolicyArns; the eks-agent-platform operator attaches it to the tenant role."
  value       = module.platform_app.app_access_policy_arn
}

output "tenant_role_arn" {
  description = "Operator-reconciled tenant role the chart's ServiceAccount is bound to via the EKS Pod Identity association."
  value       = module.platform_app.tenant_role_arn
}

output "aurora_cluster_endpoint" {
  description = "Aurora Postgres writer endpoint. Wired to the chart's tenantInfra.pgHost."
  value       = module.aurora.cluster_endpoint
}

output "aurora_cluster_port" {
  description = "Aurora Postgres port. Wired to the chart's PGPORT env."
  value       = module.aurora.cluster_port
}

output "aurora_database_name" {
  description = "Aurora Postgres database name. Wired to the chart's PGDATABASE env."
  value       = module.aurora.cluster_database_name
}

output "aurora_master_user_secret_arn" {
  description = "Secrets Manager ARN holding RDS master credentials. The chart's db-credentials ExternalSecret resolves username + password via External Secrets at pod start."
  value       = module.aurora.cluster_master_user_secret[0].secret_arn
}

output "app_secrets_name" {
  description = "Secrets Manager secret name for the application secrets (Slack + optional LLM API credentials)."
  value       = aws_secretsmanager_secret.app_secrets.name
}

output "app_secrets_arn" {
  description = "Secrets Manager secret ARN for the application secrets. The chart's app-secrets ExternalSecret resolves it at pod start."
  value       = aws_secretsmanager_secret.app_secrets.arn
}
