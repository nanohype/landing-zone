output "operator_role_arn" {
  description = "ARN of the eks-agent-platform operator IRSA role"
  value       = aws_iam_role.operator.arn
}

output "tenant_baseline_policy_arn" {
  description = "ARN of the tenant baseline managed policy"
  value       = aws_iam_policy.tenant_baseline.arn
}

output "tenant_permissions_boundary_arn" {
  description = "ARN of the tenant permissions boundary policy"
  value       = aws_iam_policy.tenant_boundary.arn
}

output "tenant_iam_path" {
  description = "IAM path under which tenant roles are minted"
  value       = local.tenant_role_path
}
