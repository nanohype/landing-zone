output "budget_name" {
  description = "The name of the monthly budget"
  value       = aws_budgets_budget.monthly.name
}

output "budget_id" {
  description = "The ID of the monthly budget"
  value       = aws_budgets_budget.monthly.id
}

output "anomaly_monitor_arn" {
  description = "Cost anomaly monitor ARN"
  value       = try(aws_ce_anomaly_monitor.this[0].arn, null)
}

output "anomaly_subscription_arn" {
  description = "Cost anomaly subscription ARN"
  value       = try(aws_ce_anomaly_subscription.this[0].arn, null)
}
