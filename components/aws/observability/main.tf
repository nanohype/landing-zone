data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  create_mode = var.observability_mode == "create"

  # The alarm destinations, resolved the same shape in both modes. create builds its own
  # severity topics and points alarms at them; adopt points the same alarms at the central
  # topics shared-observability owns (var.adopt_topic_arns), building no topics of its own.
  # Definitions stay local either way — an alarm references local ARNs and dimensions; only
  # the destination centralizes.
  topic_arns = local.create_mode ? {
    critical = aws_sns_topic.critical[0].arn
    warning  = aws_sns_topic.warning[0].arn
    info     = aws_sns_topic.info[0].arn
  } : var.adopt_topic_arns

  tags = merge(var.tags, {
    Component = "observability"
    Team      = var.team
  })
}

################################################################################
# SNS Topics — SSE-KMS
#
# CloudWatch Alarms publish to these topics; SSE-SNS makes SNS call
# kms:GenerateDataKey*/Decrypt as the cloudwatch service principal, so the key
# policy admits it (scoped to this account) or the alarm notification is dropped.
################################################################################

resource "aws_kms_key" "alerts" {
  count = local.create_mode ? 1 : 0

  description             = "${var.cluster_name} alert topic encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchAlarmPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "alerts" {
  count = local.create_mode ? 1 : 0

  name          = "alias/${var.cluster_name}-alerts"
  target_key_id = aws_kms_key.alerts[0].key_id
}

resource "aws_sns_topic" "critical" {
  count = local.create_mode ? 1 : 0

  name              = "${var.cluster_name}-alerts-critical"
  kms_master_key_id = aws_kms_key.alerts[0].arn
  tags              = local.tags
}

resource "aws_sns_topic" "warning" {
  count = local.create_mode ? 1 : 0

  name              = "${var.cluster_name}-alerts-warning"
  kms_master_key_id = aws_kms_key.alerts[0].arn
  tags              = local.tags
}

resource "aws_sns_topic" "info" {
  count = local.create_mode ? 1 : 0

  name              = "${var.cluster_name}-alerts-info"
  kms_master_key_id = aws_kms_key.alerts[0].arn
  tags              = local.tags
}

# The topic policies scope the CloudWatch publish grant to this account
# (aws:SourceAccount) — the same confused-deputy guard the alerts CMK policy
# carries. Without it, a service principal acting for any account could publish to
# these topics; SourceAccount pins the grant to alarms in this account only.
resource "aws_sns_topic_policy" "critical" {
  count = local.create_mode ? 1 : 0

  arn = aws_sns_topic.critical[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.critical[0].arn
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.account_id
        }
      }
    }]
  })
}

resource "aws_sns_topic_policy" "warning" {
  count = local.create_mode ? 1 : 0

  arn = aws_sns_topic.warning[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.warning[0].arn
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.account_id
        }
      }
    }]
  })
}

resource "aws_sns_topic_policy" "info" {
  count = local.create_mode ? 1 : 0

  arn = aws_sns_topic.info[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.info[0].arn
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.account_id
        }
      }
    }]
  })
}

################################################################################
# SNS Email Subscriptions
################################################################################

# create mode only: adopt-mode alarms publish to the central topics, whose subscriptions
# shared-observability owns — a workload cluster does not subscribe pagers to a topic it
# does not own.
resource "aws_sns_topic_subscription" "critical_email" {
  for_each = local.create_mode ? toset(var.alert_email_endpoints) : toset([])

  topic_arn = aws_sns_topic.critical[0].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "warning_email" {
  for_each = local.create_mode ? toset(var.alert_email_endpoints) : toset([])

  topic_arn = aws_sns_topic.warning[0].arn
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
  alarm_actions       = [local.topic_arns.critical]
  ok_actions          = [local.topic_arns.info]

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
  alarm_actions       = [local.topic_arns.warning]
  ok_actions          = [local.topic_arns.info]

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
  alarm_actions       = [local.topic_arns.warning]
  ok_actions          = [local.topic_arns.info]

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
  alarm_actions       = [local.topic_arns.critical]
  ok_actions          = [local.topic_arns.info]

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
  alarm_actions       = [local.topic_arns.warning]
  ok_actions          = [local.topic_arns.info]

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
