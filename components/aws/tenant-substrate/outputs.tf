output "tenant_datastores" {
  description = "Per-tenant datastore identifiers keyed by tenant id, then by datastore name — kind, ARN, connection endpoint, and (relational only) the RDS-managed master-secret ARN. The operator publishes these into each Platform CR's status so the tenant chart reads one predictable place."
  value       = { for k, m in module.tenant : k => m.datastores }
}
