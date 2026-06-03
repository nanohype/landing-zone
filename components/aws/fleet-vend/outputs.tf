output "vend_role_arn" {
  description = "ARN of the cross-account eks-fleet vend role"
  value       = aws_iam_role.vend.arn
}

output "vend_role_name" {
  description = "Name of the cross-account eks-fleet vend role"
  value       = aws_iam_role.vend.name
}

output "vend_permissions_boundary_arn" {
  description = "ARN of the permissions boundary capping the vend role and the cluster roles it mints"
  value       = aws_iam_policy.vend_boundary.arn
}

output "iam_path" {
  description = "IAM path under which the vend role and cluster roles are created"
  value       = local.iam_path
}
