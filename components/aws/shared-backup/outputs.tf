output "central_vault_arn" {
  description = "ARN of the central backup vault. Workload backup components target this as their copy_action destination."
  value       = aws_backup_vault.central.arn
}

output "central_vault_name" {
  description = "Name of the central backup vault."
  value       = aws_backup_vault.central.name
}

output "central_kms_key_arn" {
  description = "ARN of the multi-region CMK the central vault is encrypted with. A recovery region's replica of this key decrypts a cross-region restore."
  value       = aws_kms_key.central.arn
}
