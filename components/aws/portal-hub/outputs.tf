output "hub_role_arn" {
  description = "ARN of the portal worker IRSA role (set as serviceAccount.roleArn in the portal chart)"
  value       = aws_iam_role.hub.arn
}

output "hub_role_name" {
  description = "Name of the portal worker IRSA role"
  value       = aws_iam_role.hub.name
}

output "hub_permissions_boundary_arn" {
  description = "ARN of the permissions boundary capping the portal worker role"
  value       = aws_iam_policy.hub_boundary.arn
}

output "state_bucket_name" {
  description = "Portal OpenTofu state bucket (the chart's objectStore.bucket)"
  value       = aws_s3_bucket.portal_state.bucket
}
