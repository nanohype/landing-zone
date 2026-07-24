output "policy_id" {
  description = "ID of the Organizations backup policy."
  value       = aws_organizations_policy.backup.id
}

output "policy_arn" {
  description = "ARN of the Organizations backup policy."
  value       = aws_organizations_policy.backup.arn
}

output "cross_account_backup_enabled" {
  description = "Whether org-wide cross-account backup was enabled by this component."
  value       = var.enable_cross_account_backup
}
