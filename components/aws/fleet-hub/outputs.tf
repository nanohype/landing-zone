output "hub_role_arn" {
  description = "ARN of the eks-fleet-crossplane IRSA role the hub's provider-opentofu pod assumes"
  value       = aws_iam_role.hub.arn
}

output "hub_role_name" {
  description = "Name of the eks-fleet-crossplane hub role"
  value       = aws_iam_role.hub.name
}

output "hub_permissions_boundary_arn" {
  description = "ARN of the permissions boundary capping the hub role"
  value       = aws_iam_policy.hub_boundary.arn
}

output "state_bucket_name" {
  description = "Name of the fleet OpenTofu state bucket"
  value       = aws_s3_bucket.fleet_state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the fleet OpenTofu state bucket"
  value       = aws_s3_bucket.fleet_state.arn
}
