data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  tags = merge(var.tags, {
    Component = "observability"
    Team      = var.team
  })
}

################################################################################
# SNS Topics
################################################################################

resource "aws_sns_topic" "critical" {
  name = "${var.cluster_name}-alerts-critical"
  tags = local.tags
}

resource "aws_sns_topic" "warning" {
  name = "${var.cluster_name}-alerts-warning"
  tags = local.tags
}

resource "aws_sns_topic" "info" {
  name = "${var.cluster_name}-alerts-info"
  tags = local.tags
}

resource "aws_sns_topic_policy" "critical" {
  arn = aws_sns_topic.critical.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.critical.arn
    }]
  })
}

resource "aws_sns_topic_policy" "warning" {
  arn = aws_sns_topic.warning.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.warning.arn
    }]
  })
}

resource "aws_sns_topic_policy" "info" {
  arn = aws_sns_topic.info.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.info.arn
    }]
  })
}

################################################################################
# SNS Email Subscriptions
################################################################################

resource "aws_sns_topic_subscription" "critical_email" {
  for_each = toset(var.alert_email_endpoints)

  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "warning_email" {
  for_each = toset(var.alert_email_endpoints)

  topic_arn = aws_sns_topic.warning.arn
  protocol  = "email"
  endpoint  = each.value
}

################################################################################
# CloudWatch Alarms
################################################################################

resource "aws_cloudwatch_metric_alarm" "cluster_api_server_errors" {
  count = var.enable_cluster_alarms ? 1 : 0

  alarm_name          = "${var.cluster_name}-api-server-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "apiserver_request_total"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Sum"
  threshold           = var.alarm_config.api_server_error_threshold
  alarm_description   = "EKS API server 5xx error rate"
  alarm_actions       = [aws_sns_topic.critical.arn]
  ok_actions          = [aws_sns_topic.info.arn]

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "node_cpu_utilization" {
  count = var.enable_cluster_alarms ? 1 : 0

  alarm_name          = "${var.cluster_name}-node-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_config.cpu_utilization_threshold
  alarm_description   = "EKS node CPU utilization exceeds ${var.alarm_config.cpu_utilization_threshold}%"
  alarm_actions       = [aws_sns_topic.warning.arn]
  ok_actions          = [aws_sns_topic.info.arn]

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "node_memory_utilization" {
  count = var.enable_cluster_alarms ? 1 : 0

  alarm_name          = "${var.cluster_name}-node-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "node_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_config.memory_utilization_threshold
  alarm_description   = "EKS node memory utilization exceeds ${var.alarm_config.memory_utilization_threshold}%"
  alarm_actions       = [aws_sns_topic.warning.arn]
  ok_actions          = [aws_sns_topic.info.arn]

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cluster_failed_node_count" {
  count = var.enable_cluster_alarms ? 1 : 0

  alarm_name          = "${var.cluster_name}-failed-nodes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "cluster_failed_node_count"
  namespace           = "ContainerInsights"
  period              = var.alarm_config.node_not_ready_period
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "EKS cluster has failed/not-ready nodes"
  alarm_actions       = [aws_sns_topic.critical.arn]
  ok_actions          = [aws_sns_topic.info.arn]

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "pod_restart_count" {
  count = var.enable_cluster_alarms ? 1 : 0

  alarm_name          = "${var.cluster_name}-pod-restarts-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "pod_number_of_container_restarts"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "High pod restart rate in EKS cluster"
  alarm_actions       = [aws_sns_topic.warning.arn]
  ok_actions          = [aws_sns_topic.info.arn]

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = local.tags
}

################################################################################
# CloudWatch Dashboard
################################################################################

resource "aws_cloudwatch_dashboard" "eks" {
  count = var.enable_dashboard ? 1 : 0

  dashboard_name = "${var.cluster_name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Node CPU Utilization"
          metrics = [["ContainerInsights", "node_cpu_utilization", "ClusterName", var.cluster_name]]
          period  = 300
          stat    = "Average"
          region  = var.region
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Node Memory Utilization"
          metrics = [["ContainerInsights", "node_memory_utilization", "ClusterName", var.cluster_name]]
          period  = 300
          stat    = "Average"
          region  = var.region
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Pod Count"
          metrics = [
            ["ContainerInsights", "cluster_node_count", "ClusterName", var.cluster_name],
            ["ContainerInsights", "namespace_number_of_running_pods", "ClusterName", var.cluster_name],
          ]
          period = 300
          stat   = "Average"
          region = var.region
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Network (Bytes/sec)"
          metrics = [
            ["ContainerInsights", "node_network_total_bytes", "ClusterName", var.cluster_name],
          ]
          period = 300
          stat   = "Average"
          region = var.region
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Container Restarts"
          metrics = [["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", var.cluster_name]]
          period  = 300
          stat    = "Sum"
          region  = var.region
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Cluster Failed Nodes"
          metrics = [["ContainerInsights", "cluster_failed_node_count", "ClusterName", var.cluster_name]]
          period  = 300
          stat    = "Maximum"
          region  = var.region
          view    = "timeSeries"
        }
      },
    ]
  })
}
