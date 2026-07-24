output "sns_topic_arns" {
  description = "Map of alert topic ARNs by severity level. In create mode these are the topics this component built; in adopt mode they are the central topics it was pointed at. Same shape either way, so a consumer wires against one interface."
  value       = local.topic_arns
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = var.enable_dashboard ? "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${var.cluster_name}-overview" : null
}

output "alarm_arns" {
  description = "List of all child CloudWatch metric alarm ARNs (state-computers; the composites below carry the notifications)"
  value = var.enable_cluster_alarms ? [
    aws_cloudwatch_metric_alarm.cluster_api_server_errors[0].arn,
    aws_cloudwatch_metric_alarm.node_cpu_utilization[0].arn,
    aws_cloudwatch_metric_alarm.node_memory_utilization[0].arn,
    aws_cloudwatch_metric_alarm.cluster_failed_node_count[0].arn,
  ] : []
}

output "composite_alarm_arns" {
  description = "Per-cluster composite alarm ARNs by severity (critical=health-critical, warning=health-degraded) — the single notification surface per severity."
  value = var.enable_cluster_alarms ? {
    critical = aws_cloudwatch_composite_alarm.cluster_health_critical[0].arn
    warning  = aws_cloudwatch_composite_alarm.cluster_health_degraded[0].arn
  } : {}
}
