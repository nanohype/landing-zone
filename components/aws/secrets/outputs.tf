output "kms_key_arn" {
  description = "KMS key ARN for platform secrets encryption"
  value       = aws_kms_key.secrets.arn
}

output "kms_key_id" {
  description = "KMS key ID for platform secrets encryption"
  value       = aws_kms_key.secrets.key_id
}

output "kms_alias_arn" {
  description = "KMS alias ARN for platform secrets"
  value       = aws_kms_alias.secrets.arn
}

output "secret_arns" {
  description = "Map of secret key to Secrets Manager secret ARN"
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.arn }
}

output "secret_names" {
  description = "Map of secret key to Secrets Manager secret name"
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.name }
}

