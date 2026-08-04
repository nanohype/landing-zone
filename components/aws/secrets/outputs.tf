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

output "logs_kms_key_arn" {
  description = "KMS key ARN for the log path — CloudWatch log groups and Bedrock invocation-log delivery. Equal to kms_key_arn when separate_logs_key is false, which is the default. Published in both modes so consumers read one contract rather than branching on the mode; a consumer that passes kms_key_arn here instead is correct only by accident, and stops being correct the moment an environment separates."
  value       = var.separate_logs_key ? aws_kms_key.logs[0].arn : aws_kms_key.secrets.arn
}

output "secret_arns" {
  description = "Map of secret key to Secrets Manager secret ARN"
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.arn }
}

output "secret_names" {
  description = "Map of secret key to Secrets Manager secret name"
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.name }
}

