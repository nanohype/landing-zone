output "sns_topic_arns" {
  description = "Map of alert topic ARNs by severity level. In create mode these are the topics this component built; in adopt mode they are the central topics it was pointed at. Same shape either way, so a consumer wires against one interface."
  value       = local.topic_arns
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
