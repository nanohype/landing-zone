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

  # Standard fleet-alarm dimensions (observability-slo fleet_alerting): every alarm and
  # composite carries Severity + ClusterName as tags so routing and rollup key on a
  # consistent tag set, not on parsed alarm names. Environment is already present via the
  # root config's default tags, so it is not re-declared here.
  alarm_tags = {
    critical = merge(local.tags, { Severity = "critical", ClusterName = var.cluster_name })
    warning  = merge(local.tags, { Severity = "warning", ClusterName = var.cluster_name })
  }
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
      # CloudWatch alarms are not the only publisher: the agent platform's
      # kill-switch bus routes governance events (a budget breach, an SLO
      # burn-rate breach) straight to these topics. EventBridge needs the same
      # data key, and without this grant the publish is accepted and then
      # silently dropped — no error surfaces at the rule.
      {
        # Also unconditioned, for the same reason and one more. AWS does not
        # document whether EventBridge populates condition context on the KMS
        # call it makes to encrypt into an SSE-KMS topic, and an unpopulated key
        # fails closed — the same silent drop as above, one layer down.
        #
        # The guard would also buy nothing here: the topic's own resource policy
        # is the boundary for who may publish, and that policy cannot be
        # conditioned for this principal at all. A condition on the key cannot
        # restrict what the topic already admits.
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
        ]
        Resource = "*"
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
    Statement = [
      {
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
      },
      {
        # No Condition, deliberately. AWS documents that EventBridge does not
        # populate condition context on the SNS publish path — "You can't use
        # Condition blocks in Amazon SNS topic policies for EventBridge" — so an
        # aws:SourceAccount guard here never evaluates true and the statement
        # never allows. The rule reports success and the message is dropped, with
        # the only trace an unalarmed FailedInvocations counter: a paging path
        # that looks installed and delivers nothing.
        #
        # The CloudWatch statement above keeps its guard because CloudWatch does
        # populate it. This is a per-principal fact, not a house style.
        Sid       = "AllowEventBridgeRules"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.critical[0].arn
      },
    ]
  })
}

resource "aws_sns_topic_policy" "warning" {
  count = local.create_mode ? 1 : 0

  arn = aws_sns_topic.warning[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
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
      },
      {
        # No Condition, deliberately. AWS documents that EventBridge does not
        # populate condition context on the SNS publish path — "You can't use
        # Condition blocks in Amazon SNS topic policies for EventBridge" — so an
        # aws:SourceAccount guard here never evaluates true and the statement
        # never allows. The rule reports success and the message is dropped, with
        # the only trace an unalarmed FailedInvocations counter: a paging path
        # that looks installed and delivers nothing.
        #
        # The CloudWatch statement above keeps its guard because CloudWatch does
        # populate it. This is a per-principal fact, not a house style.
        Sid       = "AllowEventBridgeRules"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.warning[0].arn
      },
    ]
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
# SSM contract — the severity topic ARNs
#
# The eks-agent-platform components layer on this account and read every
# landing-zone value they need through /eks-agent-platform/<cluster-name>/, the
# same path the agent-iam contract uses; that tree is the only channel across the
# repo boundary. Its kill-switch component routes governance events straight to
# these topics — a budget breach, an SLO burn-rate breach — so it needs the ARNs
# resolvable at plan time rather than threaded through as orchestrator variables.
#
# Published unconditionally across both modes: local.topic_arns resolves to the
# topics this component created in create mode and to the central topics
# shared-observability owns in adopt mode, so one publish serves either shape and
# a consumer wires against one interface regardless.
#
# All three tiers are published, not only the two the kill-switch rules consume. The severity set is the unit the observability-slo standard defines
# (critical pages, warning tickets, info records recovery), and a discovery
# contract that carries two thirds of it invites a consumer to guess the third.
################################################################################

resource "aws_ssm_parameter" "alerts_critical_topic_arn" {
  name  = "/eks-agent-platform/${var.cluster_name}/observability/alerts_critical_topic_arn"
  type  = "String"
  value = local.topic_arns.critical
  tags  = local.tags
}

resource "aws_ssm_parameter" "alerts_warning_topic_arn" {
  name  = "/eks-agent-platform/${var.cluster_name}/observability/alerts_warning_topic_arn"
  type  = "String"
  value = local.topic_arns.warning
  tags  = local.tags
}

resource "aws_ssm_parameter" "alerts_info_topic_arn" {
  name  = "/eks-agent-platform/${var.cluster_name}/observability/alerts_info_topic_arn"
  type  = "String"
  value = local.topic_arns.info
  tags  = local.tags
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
# CloudWatch Alarms — child state-computers
#
# These carry NO SNS action. Per observability-slo's fleet_alerting contract they
# exist only to compute state; the per-severity composite alarms below OR them
# together and own the notification, so a hard-down cluster pages once rather than
# once per firing alarm. Each is tagged with its Severity + ClusterName so the
# rollup and any downstream routing key on tags, not on parsed names.
################################################################################

resource "aws_cloudwatch_metric_alarm" "cluster_api_server_errors" {
  count = var.enable_cluster_alarms ? 1 : 0

  alarm_name          = "${var.cluster_name}-api-server-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  # apiserver_request_total_5xx, NOT apiserver_request_total. The latter counts
  # ALL API-server requests and carries the same ClusterName rollup, so a
  # perfectly healthy cluster clears any sane 5xx threshold on it within
  # seconds — this alarm would latch in ALARM and page through its critical
  # composite continuously. The mistake read as harmless only while nothing
  # published the ContainerInsights namespace at all.
  metric_name       = "apiserver_request_total_5xx"
  namespace         = "ContainerInsights"
  period            = 300
  statistic         = "Sum"
  threshold         = var.alarm_config.api_server_error_threshold
  alarm_description = "EKS API server 5xx responses exceed ${var.alarm_config.api_server_error_threshold} per 5 minutes"

  # Missing data is a fault here, not health. Every metric this component alarms on
  # comes from the amazon-cloudwatch-observability agent; if that stops publishing —
  # node exhaustion, an addon rollback, a broken Pod Identity binding — CloudWatch's
  # default of `missing` drops these alarms to INSUFFICIENT_DATA, which a composite
  # does not treat as ALARM. The cluster then reads healthy precisely because it has
  # stopped reporting. A silent workload and a well workload must not look alike.
  treat_missing_data = "breaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = local.alarm_tags.critical
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

  # Saturation, not liveness: absence of a utilization datapoint says nothing about
  # whether the cluster is saturated, and treating it as breaching would page on the
  # same missing-agent condition the liveness alarms above already cover once.
  treat_missing_data = "missing"

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = local.alarm_tags.warning
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

  # Saturation, not liveness: absence of a utilization datapoint says nothing about
  # whether the cluster is saturated, and treating it as breaching would page on the
  # same missing-agent condition the liveness alarms above already cover once.
  treat_missing_data = "missing"

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = local.alarm_tags.warning
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

  # Same reasoning as the API-server alarm: this is a liveness signal, so no data
  # is a fault rather than an all-clear.
  treat_missing_data = "breaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = local.alarm_tags.critical
}

################################################################################
# Composite Alarms — per-cluster, per-severity rollups
#
# The single notification surface. Each ORs its child alarms (referenced by name,
# which also orders creation after them) and owns the SNS action for its tier; the
# children stay actionless. The critical composite pages once for a hard-down
# cluster (API 5xx OR failed nodes); the degraded composite raises one ticket for
# a broadly saturated one (CPU OR memory). Both resolve to the info tier once on
# OK. Publishes to local topics in create mode, to the central
# shared-observability topics in adopt mode — local.topic_arns resolves either.
################################################################################

resource "aws_cloudwatch_composite_alarm" "cluster_health_critical" {
  count = var.enable_cluster_alarms ? 1 : 0

  alarm_name        = "${var.cluster_name}-health-critical"
  alarm_description = "Critical cluster-health rollup — API server 5xx or failed/not-ready nodes. One page for a hard-down cluster."
  alarm_actions     = [local.topic_arns.critical]
  ok_actions        = [local.topic_arns.info]

  # The page-tier SLO burn-rate pairs roll up here rather than notifying on their
  # own, so a cluster that is both hard-down and burning its budget still pages
  # once. slo.tf builds them; the lookup is empty when the SLO is disabled.
  alarm_rule = join(" OR ", concat(
    [
      "ALARM(\"${aws_cloudwatch_metric_alarm.cluster_api_server_errors[0].alarm_name}\")",
      "ALARM(\"${aws_cloudwatch_metric_alarm.cluster_failed_node_count[0].alarm_name}\")",
    ],
    [
      for key, c in aws_cloudwatch_composite_alarm.slo_burn :
      "ALARM(\"${c.alarm_name}\")" if local.slo_burn_windows[key].severity == "critical"
    ],
  ))

  tags = local.alarm_tags.critical
}

resource "aws_cloudwatch_composite_alarm" "cluster_health_degraded" {
  count = var.enable_cluster_alarms ? 1 : 0

  alarm_name        = "${var.cluster_name}-health-degraded"
  alarm_description = "Degraded cluster-health rollup — node CPU or memory saturation. One ticket for a broadly degraded cluster."
  alarm_actions     = [local.topic_arns.warning]
  ok_actions        = [local.topic_arns.info]

  # The ticket-tier SLO burn-rate pairs roll up here for the same reason the
  # page-tier pairs roll up into the critical composite: one ticket per cluster,
  # not one per window pair.
  alarm_rule = join(" OR ", concat(
    [
      "ALARM(\"${aws_cloudwatch_metric_alarm.node_cpu_utilization[0].alarm_name}\")",
      "ALARM(\"${aws_cloudwatch_metric_alarm.node_memory_utilization[0].alarm_name}\")",
    ],
    [
      for key, c in aws_cloudwatch_composite_alarm.slo_burn :
      "ALARM(\"${c.alarm_name}\")" if local.slo_burn_windows[key].severity == "warning"
    ],
  ))

  tags = local.alarm_tags.warning
}

################################################################################
# CloudWatch Dashboard
################################################################################

# The board a cluster represents itself with.
#
# Row order is the reading order: the SLO first, then what moves it (errors,
# traffic, latency), then the resources that explain those (saturation). The
# failure-state panel sits with the saturation row rather than last on its own,
# because the end of a scan is where a load-bearing panel goes unseen.
#
# Every series is a cluster-substrate noun — the API server, its request stream,
# its nodes — rather than generic infrastructure. A board of node CPU and memory
# alone shows the host of the system rather than the system, which the
# observability-slo standard names as not representing it at all.
resource "aws_cloudwatch_dashboard" "eks" {
  count = var.enable_dashboard ? 1 : 0

  dashboard_name = "${var.cluster_name}-overview"

  dashboard_body = jsonencode({
    widgets = concat(
      # ── SLO ──────────────────────────────────────────────────────────────────
      # Present only when the SLO is declared: a budget gauge with no objective
      # behind it is a number with no meaning.
      local.slo_enabled ? [
        {
          type   = "metric"
          x      = 0
          y      = 0
          width  = 8
          height = 6
          properties = {
            title = "Availability SLI vs objective (30d)"
            metrics = [
              [{ id = "e", expression = "SUM(errors)", visible = false }],
              [{ id = "r", expression = "SUM(requests)", visible = false }],
              [{ id = "sli", expression = "IF(r > 0, (1 - e / r) * 100, 100)", label = "SLI %" }],
              ["ContainerInsights", "apiserver_request_total_5xx", "ClusterName", var.cluster_name, { id = "errors", visible = false }],
              ["ContainerInsights", "apiserver_request_total", "ClusterName", var.cluster_name, { id = "requests", visible = false }],
            ]
            period = 2592000
            stat   = "Sum"
            region = var.region
            view   = "singleValue"
            annotations = {
              horizontal = [{
                label = "objective"
                value = var.slo_availability_objective * 100
              }]
            }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 0
          width  = 8
          height = 6
          properties = {
            title = "Error budget remaining (30d)"
            metrics = [
              [{ id = "e2", expression = "SUM(be)", visible = false }],
              [{ id = "r2", expression = "SUM(br)", visible = false }],
              [{ id = "budget", expression = "IF(r2 > 0, (1 - (e2 / r2) / ${local.slo_error_budget}) * 100, 100)", label = "Budget remaining %" }],
              ["ContainerInsights", "apiserver_request_total_5xx", "ClusterName", var.cluster_name, { id = "be", visible = false }],
              ["ContainerInsights", "apiserver_request_total", "ClusterName", var.cluster_name, { id = "br", visible = false }],
            ]
            period = 2592000
            stat   = "Sum"
            region = var.region
            view   = "gauge"
            yAxis  = { left = { min = 0, max = 100 } }
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 0
          width  = 8
          height = 6
          properties = {
            title = "Budget burn rate — fast (1h) and slow (6h)"
            metrics = [
              [{ id = "fb", expression = "IF(fr > 0, (fe / fr) / ${local.slo_error_budget}, 0)", label = "1h burn" }],
              [{ id = "sb", expression = "IF(sr > 0, (se / sr) / ${local.slo_error_budget}, 0)", label = "6h burn" }],
              ["ContainerInsights", "apiserver_request_total_5xx", "ClusterName", var.cluster_name, { id = "fe", period = 3600, visible = false }],
              ["ContainerInsights", "apiserver_request_total", "ClusterName", var.cluster_name, { id = "fr", period = 3600, visible = false }],
              ["ContainerInsights", "apiserver_request_total_5xx", "ClusterName", var.cluster_name, { id = "se", period = 21600, visible = false }],
              ["ContainerInsights", "apiserver_request_total", "ClusterName", var.cluster_name, { id = "sr", period = 21600, visible = false }],
            ]
            stat   = "Sum"
            region = var.region
            view   = "timeSeries"
            annotations = {
              horizontal = [
                { label = "page (14.4x)", value = 14.4 },
                { label = "ticket (3x)", value = 3 },
              ]
            }
          }
        },
      ] : [],

      # ── Errors and traffic ───────────────────────────────────────────────────
      [
        {
          type   = "metric"
          x      = 0
          y      = 6
          width  = 12
          height = 6
          properties = {
            title = "API server error ratio"
            metrics = [
              [{ id = "ratio", expression = "IF(tr > 0, (te / tr) * 100, 0)", label = "5xx %" }],
              ["ContainerInsights", "apiserver_request_total_5xx", "ClusterName", var.cluster_name, { id = "te", visible = false }],
              ["ContainerInsights", "apiserver_request_total", "ClusterName", var.cluster_name, { id = "tr", visible = false }],
            ]
            period = 300
            stat   = "Sum"
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
            title = "API server request rate and 5xx"
            metrics = [
              ["ContainerInsights", "apiserver_request_total", "ClusterName", var.cluster_name, { label = "requests" }],
              ["ContainerInsights", "apiserver_request_total_5xx", "ClusterName", var.cluster_name, { label = "5xx" }],
            ]
            period = 300
            stat   = "Sum"
            region = var.region
            view   = "timeSeries"
          }
        },

        # ── Latency ────────────────────────────────────────────────────────────
        # Quantiles from the request-duration series, never an average: an average
        # latency hides the tail that the requests people notice live in.
        {
          type   = "metric"
          x      = 0
          y      = 12
          width  = 12
          height = 6
          properties = {
            title = "API server request duration (p50 / p95 / p99)"
            metrics = [
              ["ContainerInsights", "apiserver_request_duration_seconds", "ClusterName", var.cluster_name, { label = "p50", stat = "p50" }],
              ["...", { label = "p95", stat = "p95" }],
              ["...", { label = "p99", stat = "p99" }],
            ]
            period = 300
            region = var.region
            view   = "timeSeries"
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 12
          width  = 12
          height = 6
          properties = {
            title   = "API server in-flight requests"
            metrics = [["ContainerInsights", "apiserver_current_inflight_requests", "ClusterName", var.cluster_name]]
            period  = 300
            stat    = "Maximum"
            region  = var.region
            view    = "timeSeries"
          }
        },

        # ── Saturation ─────────────────────────────────────────────────────────
        {
          type   = "metric"
          x      = 0
          y      = 18
          width  = 8
          height = 6
          properties = {
            title   = "Node CPU utilization"
            metrics = [["ContainerInsights", "node_cpu_utilization", "ClusterName", var.cluster_name]]
            period  = 300
            stat    = "Average"
            region  = var.region
            view    = "timeSeries"
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 18
          width  = 8
          height = 6
          properties = {
            title   = "Node memory utilization"
            metrics = [["ContainerInsights", "node_memory_utilization", "ClusterName", var.cluster_name]]
            period  = 300
            stat    = "Average"
            region  = var.region
            view    = "timeSeries"
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 18
          width  = 8
          height = 6
          properties = {
            # Titled for both series it draws. A panel titled for one of two
            # metrics sends a reader to the wrong runbook: a node scale-down and a
            # pod eviction look identical under a title that claims only one.
            title = "Nodes and running pods"
            metrics = [
              ["ContainerInsights", "cluster_node_count", "ClusterName", var.cluster_name, { label = "nodes" }],
              ["ContainerInsights", "namespace_number_of_running_pods", "ClusterName", var.cluster_name, { label = "running pods" }],
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
          y      = 24
          width  = 12
          height = 6
          properties = {
            title   = "Failed / not-ready nodes"
            metrics = [["ContainerInsights", "cluster_failed_node_count", "ClusterName", var.cluster_name]]
            period  = 300
            stat    = "Maximum"
            region  = var.region
            view    = "timeSeries"
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 24
          width  = 12
          height = 6
          properties = {
            title   = "Node network throughput (bytes/sec)"
            metrics = [["ContainerInsights", "node_network_total_bytes", "ClusterName", var.cluster_name]]
            period  = 300
            stat    = "Average"
            region  = var.region
            view    = "timeSeries"
          }
        },
      ],
    )
  })
}
