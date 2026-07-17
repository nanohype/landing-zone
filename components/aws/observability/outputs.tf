output "sns_topic_arns" {
  description = "Map of SNS topic ARNs by severity level"
  value = {
    critical = aws_sns_topic.critical.arn
    warning  = aws_sns_topic.warning.arn
    info     = aws_sns_topic.info.arn
  }
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = var.enable_dashboard ? "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${var.cluster_name}-overview" : null
}

output "alarm_arns" {
  description = "List of all CloudWatch alarm ARNs"
  value = var.enable_cluster_alarms ? [
    aws_cloudwatch_metric_alarm.cluster_api_server_errors[0].arn,
    aws_cloudwatch_metric_alarm.node_cpu_utilization[0].arn,
    aws_cloudwatch_metric_alarm.node_memory_utilization[0].arn,
    aws_cloudwatch_metric_alarm.cluster_failed_node_count[0].arn,
    aws_cloudwatch_metric_alarm.pod_restart_count[0].arn,
  ] : []
}
