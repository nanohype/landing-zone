output "cilium_version" {
  description = "Deployed Cilium version"
  value       = helm_release.cilium.version
}

output "argocd_namespace" {
  description = "ArgoCD namespace"
  value       = helm_release.argocd.namespace
}

output "portal_reader_sa" {
  description = "ServiceAccount the portal's tenant watcher authenticates as (read-only on Platform/Tenant CRs)"
  value       = var.enable_portal_reader ? kubernetes_service_account_v1.portal_reader[0].metadata[0].name : ""
}

output "portal_reader_token" {
  description = "Durable bearer token for portal-reader. Feed to the portal cluster registration with the cluster endpoint + CA so no manual token minting is needed."
  value       = var.enable_portal_reader ? kubernetes_secret_v1.portal_reader_token[0].data["token"] : ""
  sensitive   = true
}
