output "role_arn" {
  description = "ARN of the break-glass IAM role"
  value       = aws_iam_role.break_glass.arn
}

output "role_name" {
  description = "Name of the break-glass IAM role"
  value       = aws_iam_role.break_glass.name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for break-glass alerts"
  value       = aws_sns_topic.break_glass.arn
}
