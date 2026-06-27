output "unwedge_role_arn" {
  description = "ARN of the cross-account eks-fleet break-glass unwedge role"
  value       = aws_iam_role.unwedge.arn
}

output "unwedge_role_name" {
  description = "Name of the cross-account eks-fleet break-glass unwedge role"
  value       = aws_iam_role.unwedge.name
}

output "unwedge_permissions_boundary_arn" {
  description = "ARN of the permissions boundary capping the unwedge role"
  value       = aws_iam_policy.unwedge_boundary.arn
}
