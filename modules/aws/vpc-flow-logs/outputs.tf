output "flow_log_id" {
  description = "ID of the aws_flow_log resource."
  value       = aws_flow_log.this.id
}

output "log_group_name" {
  description = "Name of the CloudWatch log group the flow log writes to."
  value       = aws_cloudwatch_log_group.this.name
}

output "log_group_arn" {
  description = "ARN of the CloudWatch log group the flow log writes to."
  value       = aws_cloudwatch_log_group.this.arn
}

output "iam_role_arn" {
  description = "ARN of the IAM role the flow-log service assumes."
  value       = aws_iam_role.this.arn
}

output "iam_role_name" {
  description = "Name of the IAM role the flow-log service assumes."
  value       = aws_iam_role.this.name
}

output "traffic_type" {
  description = "Traffic type captured by the flow log."
  value       = aws_flow_log.this.traffic_type
}
