output "tenant_datastores" {
  description = "Per-tenant datastore identifiers keyed by tenant id, then by datastore name — kind, ARN, connection endpoint, and (relational only) the RDS-managed master-secret ARN. Relational secret ARNs are also published to SSM under /eks-agent-platform/<cluster>/tenant-substrate/, where the operator reads them to scope each tenant's Secrets Manager grant to its own secret."
  value       = { for k, m in module.tenant : k => m.datastores }
}

output "tenant_kms_key_arns" {
  description = "Per-tenant customer-managed key ARN, keyed by tenant id. Also published to SSM under /eks-agent-platform/<cluster>/tenant-substrate/<tenant>/kms_key_arn, where the operator reads it to scope the tenant role's KMS grant."
  value       = { for k, m in module.tenant : k => m.kms_key_arn }
}
