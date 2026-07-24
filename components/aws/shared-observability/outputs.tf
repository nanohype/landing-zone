output "sns_topic_arns" {
  description = "Map of central alert topic ARNs by severity (critical / warning / info). Workload observability adopts these as its alarm actions, matching the shape observability's own sns_topic_arns output carries in create mode."
  value       = { for sev, topic in aws_sns_topic.this : sev => topic.arn }
}

output "alert_kms_key_arn" {
  description = "ARN of the org-scoped CMK the central alert topics are encrypted with."
  value       = aws_kms_key.alerts.arn
}
