# Returned to the provider-opentofu Workspace's status.atProvider.outputs, which
# the eks-fleet Cluster composition maps onto the claim's status. Names match the
# Cluster XRD's status fields.

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA certificate"
  value       = module.cluster.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = module.cluster.cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN (for tenant IRSA)"
  value       = module.cluster.oidc_provider_arn
}

output "oidc_issuer" {
  description = "OIDC issuer URL (no scheme)"
  value       = module.cluster.oidc_issuer
}

output "karpenter_iam_role_arn" {
  description = "Karpenter controller IAM role ARN"
  value       = module.cluster.karpenter_iam_role_arn
}

output "vpc_id" {
  description = "The VPC the cluster lands in"
  value       = module.network.vpc_id
}
