################################################################################
# Cluster availability SLO — SLI, error budget, and multi-window burn-rate alerts
#
# The observability-slo standard requires every system to declare at least one SLO
# with a multi-window multi-burn-rate error budget. This is the cluster
# substrate's: the fraction of Kubernetes API-server requests that are not 5xx.
#
# The apiserver is the right subject and it has to be measured here. It belongs to
# no Platform tenant, so nothing at the tenant layer can express its objective —
# the layer above holds per-Platform objectives and has no Platform to attach this
# one to.
#
# ── The SLI ──
#
# good / valid = 1 - (apiserver_request_total_5xx / apiserver_request_total), both
# from the enhanced Container Insights control-plane set the alarms in main.tf
# already read, with the same ClusterName-only rollup. The cluster component
# asserts that set is enabled (enhanced_container_insights), so the series the
# panels and alarms below draw on have a producer.
#
# ── Why composites rather than one alarm per window pair ──
#
# The standard's burn-rate alert fires only when BOTH a long and a short window
# exceed the factor, which suppresses a one-off spike while still catching a fast
# burn. A single CloudWatch alarm cannot express that: every metric in one
# metric-math alarm must share a period, so a long and a short window cannot be
# compared inside one expression.
#
# So each window pair is two actionless metric alarms and a composite that ANDs
# them — the same shape the cluster-health rollups in main.tf use, for the same
# reason. The pair composites carry no action of their own either; they feed the
# per-severity cluster composites, so a cluster burning its budget still pages
# once from the critical composite rather than once per window pair.
#
# ── The 3-day window ──
#
# CloudWatch caps a metric period at 86400s, so the standard's 3d window is
# rendered as three consecutive 1-day evaluations (evaluation_periods = 3,
# datapoints_to_alarm = 3) rather than one 3-day ratio. That is stricter than the
# standard asks: it requires the burn to persist across all three days rather than
# to average out over them, so it fires less often and never more.
################################################################################

locals {
  # budget = 1 - objective. The burn rate is the error ratio expressed in budgets
  # per SLO window: 1.0 exhausts the whole budget exactly over the window.
  slo_error_budget = 1 - var.slo_availability_objective

  # The standard's four window pairs. `long_periods` renders a window longer than
  # CloudWatch's 86400s period cap as consecutive evaluations of the cap.
  slo_burn_windows = {
    fast = {
      long_period   = 3600
      long_periods  = 1
      short_period  = 300
      factor        = 14.4
      severity      = "critical"
      budget_spent  = "2% of the 30d budget in 1h"
      window_labels = "1h and 5m"
    }
    quick = {
      long_period   = 21600
      long_periods  = 1
      short_period  = 1800
      factor        = 6
      severity      = "critical"
      budget_spent  = "5% of the 30d budget in 6h"
      window_labels = "6h and 30m"
    }
    steady = {
      long_period   = 86400
      long_periods  = 1
      short_period  = 7200
      factor        = 3
      severity      = "warning"
      budget_spent  = "10% of the 30d budget in 1d"
      window_labels = "1d and 2h"
    }
    slow = {
      long_period   = 86400
      long_periods  = 3
      short_period  = 21600
      factor        = 1
      severity      = "warning"
      budget_spent  = "10% of the 30d budget in 3d"
      window_labels = "3d and 6h"
    }
  }

  # One entry per (pair, side) so the eight metric alarms are a single for_each
  # rather than eight near-identical blocks.
  slo_burn_alarms = merge([
    for key, w in local.slo_burn_windows : {
      for side in ["long", "short"] :
      "${key}-${side}" => {
        pair        = key
        side        = side
        period      = side == "long" ? w.long_period : w.short_period
        periods     = side == "long" ? w.long_periods : 1
        factor      = w.factor
        severity    = w.severity
        window_desc = w.window_labels
      }
    }
  ]...)

  slo_enabled = var.enable_cluster_alarms && var.enable_slo_alarms
}

# The eight window alarms. Actionless: they exist to compute state, and the pair
# composites below decide when that state is worth telling anyone about.
resource "aws_cloudwatch_metric_alarm" "slo_burn_window" {
  for_each = local.slo_enabled ? local.slo_burn_alarms : {}

  alarm_name          = "${var.cluster_name}-slo-burn-${each.key}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = each.value.periods
  datapoints_to_alarm = each.value.periods
  threshold           = each.value.factor
  alarm_description   = "API-server availability budget burning at >= ${each.value.factor}x over the ${each.value.side} window (${each.value.window_desc} pair). Half of a burn-rate pair — the composite decides."

  # No traffic means no errors means no burn. The cluster being unreachable is a
  # different fact, and the liveness alarms in main.tf carry it — duplicating it
  # here would page twice for one condition.
  treat_missing_data = "notBreaching"

  metric_query {
    id          = "errors"
    return_data = false

    metric {
      metric_name = "apiserver_request_total_5xx"
      namespace   = "ContainerInsights"
      period      = each.value.period
      stat        = "Sum"
      dimensions  = { ClusterName = var.cluster_name }
    }
  }

  metric_query {
    id          = "requests"
    return_data = false

    metric {
      metric_name = "apiserver_request_total"
      namespace   = "ContainerInsights"
      period      = each.value.period
      stat        = "Sum"
      dimensions  = { ClusterName = var.cluster_name }
    }
  }

  metric_query {
    id          = "burn_rate"
    label       = "Budget burn rate (${each.value.window_desc} ${each.value.side})"
    return_data = true

    # The IF guards the denominator: a window with no requests would otherwise
    # divide by zero, and CloudWatch renders that as missing data rather than as
    # the zero burn it actually is.
    expression = "IF(requests > 0, (errors / requests) / ${local.slo_error_budget}, 0)"
  }

  tags = local.alarm_tags[each.value.severity]
}

# The pair composites. Also actionless — they roll up into the per-severity
# cluster composites in main.tf, which own the notification.
resource "aws_cloudwatch_composite_alarm" "slo_burn" {
  for_each = local.slo_enabled ? local.slo_burn_windows : {}

  alarm_name        = "${var.cluster_name}-slo-burn-${each.key}"
  alarm_description = "API-server availability budget burning at >= ${each.value.factor}x over BOTH windows of the ${each.value.window_labels} pair — ${each.value.budget_spent}."

  alarm_rule = join(" AND ", [
    "ALARM(\"${aws_cloudwatch_metric_alarm.slo_burn_window["${each.key}-long"].alarm_name}\")",
    "ALARM(\"${aws_cloudwatch_metric_alarm.slo_burn_window["${each.key}-short"].alarm_name}\")",
  ])

  tags = local.alarm_tags[each.value.severity]
}
