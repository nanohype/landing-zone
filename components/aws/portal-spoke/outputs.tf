output "spoke_role_arn" {
  description = "ARN of the portal cross-account spoke role (set as the Account's AssumeRoleARN in portal)"
  value       = aws_iam_role.spoke.arn
}

output "spoke_role_name" {
  description = "Name of the portal cross-account spoke role"
  value       = aws_iam_role.spoke.name
}

output "spoke_permissions_boundary_arn" {
  description = "ARN of the permissions boundary capping the spoke role"
  value       = aws_iam_policy.spoke_boundary.arn
}

output "external_id" {
  description = "The sts:ExternalId portal must present (set as the Account's ExternalID in portal)"
  value       = var.external_id
}
