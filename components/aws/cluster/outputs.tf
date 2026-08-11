################################################################################
# Cluster Outputs
################################################################################

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID — attached to the CONTROL PLANE's ENIs. Not the source of pod traffic: see node_security_group_id."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "EKS node security group ID — attached to the worker nodes' ENIs, and therefore the source of every packet a pod sends out of the cluster. This is what a datastore's ingress rule has to allow."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = module.eks.oidc_provider_arn
}

output "oidc_issuer" {
  description = "OIDC issuer URL (without https://)"
  value       = local.oidc_issuer
}

# Karpenter outputs
output "karpenter_iam_role_arn" {
  description = "Karpenter controller IAM role ARN"
  value       = module.karpenter.iam_role_arn
}

output "karpenter_node_role_name" {
  description = "Karpenter node IAM role name"
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_instance_profile_name" {
  description = "Karpenter instance profile name"
  value       = module.karpenter.instance_profile_name
}

output "karpenter_queue_name" {
  description = "Karpenter SQS interruption queue name"
  value       = module.karpenter.queue_name
}
