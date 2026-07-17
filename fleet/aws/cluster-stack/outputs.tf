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

output "private_subnet_ids" {
  description = "Private subnet IDs the cluster nodes run in (status plumbing for cluster-bootstrap adopt-mode publishing)"
  value       = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs for load balancers"
  value       = module.network.public_subnet_ids
}

output "private_subnet_azs" {
  description = "Availability zones of the private subnets, in the same order as private_subnet_ids"
  value       = module.network.private_subnet_azs
}

output "private_subnet_az_ids" {
  description = "AWS AZ IDs (e.g. usw2-az1) of the private subnets, in the same order as private_subnet_ids. Cross-account-stable, so this is the field the Cluster status should surface (AZ names remap per account)."
  value       = module.network.private_subnet_az_ids
}

output "public_subnet_az_ids" {
  description = "AWS AZ IDs (e.g. usw2-az1) of the public subnets, in the same order as public_subnet_ids. Cross-account-stable companion to public_subnet_ids."
  value       = module.network.public_subnet_az_ids
}
