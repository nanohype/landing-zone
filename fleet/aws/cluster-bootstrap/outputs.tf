# Returned to the provider-opentofu Workspace's status.atProvider.outputs. The
# portal_reader_token lets the portal register the bootstrapped cluster with a
# durable read-only token (no manual minting); the rest are observability.

output "operator_role_arn" {
  description = "The eks-agent-platform operator IRSA role ARN"
  value       = module.agent_iam.operator_role_arn
}

output "argocd_namespace" {
  description = "ArgoCD namespace on the bootstrapped cluster"
  value       = module.cluster_bootstrap.argocd_namespace
}

output "portal_reader_sa" {
  description = "Read-only ServiceAccount the portal authenticates as (Platform/Tenant CR watcher)"
  value       = module.cluster_bootstrap.portal_reader_sa
}

output "portal_reader_token" {
  description = "Durable bearer token for portal-reader. Feed to the portal cluster registration with the endpoint + CA."
  value       = module.cluster_bootstrap.portal_reader_token
  sensitive   = true
}
