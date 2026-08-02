output "budget_name" {
  description = "The name of the org monthly budget"
  value       = aws_budgets_budget.org_monthly.name
}

output "budget_id" {
  description = "The ID of the org monthly budget"
  value       = aws_budgets_budget.org_monthly.id
}

output "anomaly_monitor_service_arn" {
  description = "Cost anomaly monitor (by service) ARN"
  value       = try(aws_ce_anomaly_monitor.service[0].arn, null)
}

output "anomaly_monitor_account_arn" {
  description = "Cost anomaly monitor (by linked account) ARN"
  value       = try(aws_ce_anomaly_monitor.linked_account[0].arn, null)
}

output "anomaly_subscription_arn" {
  description = "Cost anomaly subscription ARN"
  value       = try(aws_ce_anomaly_subscription.this[0].arn, null)
}

output "cur_export_bucket_name" {
  description = "CUR 2.0 export S3 bucket name"
  value       = try(module.cur_bucket[0].s3_bucket_id, null)
}

output "cur_export_name" {
  description = "CUR 2.0 export name. The data lands under <prefix>/<name>/ in the export bucket."
  value       = var.enable_cur_export ? local.cur_export_name : null
}

output "cur_export_prefix" {
  description = "S3 key prefix the CUR 2.0 export delivers under."
  value       = var.enable_cur_export ? local.cur_export_prefix : null
}

output "cur_export_iam_principal_data" {
  description = "Whether the CUR 2.0 export carries caller-identity (IAM principal) allocation data. Without it there is no line_item_iam_principal column and no iamPrincipal/* tag columns, so Amazon Bedrock spend cannot be attributed to anything."
  value       = try(aws_bcmdataexports_export.cur[0].export[0].data_query[0].table_configurations["COST_AND_USAGE_REPORT"]["INCLUDE_IAM_PRINCIPAL_DATA"], null)
}

output "cost_category_arns" {
  description = "Map of cost category name to ARN"
  value = {
    for k, v in aws_ce_cost_category.this : k => v.arn
  }
}
