# Unit tests for observability's alert-topic encryption. CloudWatch alarms publish
# to three severity-tiered SNS topics (critical / warning / info); the contract
# under test is that ALL three are SSE-KMS with the DEDICATED alerts customer-managed
# key (not unencrypted, and not the AWS-managed alias/aws/sns — which cannot grant
# the cloudwatch service principal), and that the dedicated key's policy admits
# exactly that publisher, scoped to this account. Drop the encryption on any tier or
# swap in the managed key and that tier's alarm notification is either sent in the
# clear or silently dropped.
#
# Runs at command = plan against a mocked AWS provider. Each topic's kms_master_key_id
# is wired to the alerts key ARN and the key policy is jsonencode()'d, so both render
# for real at plan time.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDTEST"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }
  # The mock's random default isn't a parseable ARN; pin the key + topics so the
  # CloudWatch alarms' alarm_actions/ok_actions (the topic ARNs) and the SNS topic
  # policies (topic ARN) plan cleanly.
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:123456789012:key/mock"
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:mock"
    }
  }
}

variables {
  environment  = "development"
  region       = "us-east-1"
  cluster_name = "development-platform"
  team         = "platform"
}

# create mode (default): all three severity topics are SSE-KMS with the dedicated alerts CMK.
run "all_alert_topics_are_sse_kms_with_dedicated_cmk" {
  command = plan

  assert {
    condition = (
      aws_sns_topic.critical[0].kms_master_key_id == aws_kms_key.alerts[0].arn
      && aws_sns_topic.warning[0].kms_master_key_id == aws_kms_key.alerts[0].arn
      && aws_sns_topic.info[0].kms_master_key_id == aws_kms_key.alerts[0].arn
    )
    error_message = "the critical/warning/info alert topics must each be SSE-KMS referencing the dedicated alerts CMK ARN (never unencrypted or alias/aws/sns)"
  }
}

# The dedicated alerts CMK's policy admits the CloudWatch alarm publisher,
# SourceAccount-scoped.
run "alerts_key_admits_cloudwatch_publisher" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.alerts[0].policy).Statement :
      s if try(s.Principal.Service, "") == "cloudwatch.amazonaws.com"
      && contains(try(tolist(s.Action), [s.Action]), "kms:GenerateDataKey*")
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "alerts CMK policy must admit cloudwatch.amazonaws.com for kms:GenerateDataKey*, scoped by aws:SourceAccount"
  }
}

# Every statement on every severity topic is SNS:Publish, by a named AWS service
# principal, scoped by aws:SourceAccount — the confused-deputy guard the sibling
# CMK policy already carries. The invariant is the scoping, not the identity of
# the publisher: without it a service principal acting for any account could
# publish into this cluster's pager.
run "topic_policies_scope_publish_by_source_account" {
  command = plan

  # CloudWatch's grants carry the account guard. EventBridge's deliberately do
  # not — see the AllowEventBridgeRules comment — so the assertion is
  # per-principal rather than blanket. A blanket rule here is what would push
  # someone to "fix" the EventBridge statement by adding a condition that
  # silently kills every page.
  assert {
    condition = alltrue([
      for p in [
        aws_sns_topic_policy.critical[0].policy,
        aws_sns_topic_policy.warning[0].policy,
        aws_sns_topic_policy.info[0].policy,
        ] : alltrue([
          for s in jsondecode(p).Statement :
          contains(["cloudwatch.amazonaws.com", "events.amazonaws.com"], try(s.Principal.Service, ""))
          && s.Action == "SNS:Publish"
          && (
            try(s.Principal.Service, "") != "cloudwatch.amazonaws.com"
            || try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
          )
      ])
    ])
    error_message = "every topic-policy statement must grant SNS:Publish to an approved service principal, and every CloudWatch statement must carry the aws:SourceAccount guard"
  }

  # CloudWatch alarms reach all three tiers; that is what the alarms in this
  # component are for, and a generalized guard above must not let it be dropped.
  assert {
    condition = alltrue([
      for p in [
        aws_sns_topic_policy.critical[0].policy,
        aws_sns_topic_policy.warning[0].policy,
        aws_sns_topic_policy.info[0].policy,
        ] : anytrue([
          for s in jsondecode(p).Statement :
          try(s.Principal.Service, "") == "cloudwatch.amazonaws.com"
      ])
    ])
    error_message = "every severity topic must still admit cloudwatch.amazonaws.com — the alarms in this component publish through it"
  }
}

# The agent-platform kill-switch bus routes governance events — a budget breach,
# an SLO burn-rate breach — straight to the paging and ticket tiers. EventBridge
# publishes through the topic's own resource policy rather than an assumed role,
# and the topics are SSE-KMS, so it needs the CMK grant too. Miss either and the
# publish is accepted and then silently dropped, with no error at the rule.
run "eventbridge_can_publish_to_the_paging_tiers" {
  command = plan

  assert {
    condition = alltrue([
      for p in [
        aws_sns_topic_policy.critical[0].policy,
        aws_sns_topic_policy.warning[0].policy,
        ] : anytrue([
          for s in jsondecode(p).Statement :
          try(s.Principal.Service, "") == "events.amazonaws.com" && s.Action == "SNS:Publish"
      ])
    ])
    error_message = "the critical and warning topics must admit events.amazonaws.com for SNS:Publish — the kill-switch bus routes governance events to them"
  }

  # The load-bearing half. AWS: "You can't use Condition blocks in Amazon SNS
  # topic policies for EventBridge." A condition here never evaluates true, so
  # the statement never allows, the rule still reports success, and the page is
  # dropped with nothing but an unalarmed FailedInvocations counter to show for
  # it. This asserts nobody re-adds one.
  assert {
    condition = alltrue([
      for p in [
        aws_sns_topic_policy.critical[0].policy,
        aws_sns_topic_policy.warning[0].policy,
        aws_sns_topic_policy.info[0].policy,
        ] : alltrue([
          for s in jsondecode(p).Statement :
          !can(s.Condition)
          if try(s.Principal.Service, "") == "events.amazonaws.com"
      ])
    ])
    error_message = "an EventBridge statement on an SNS topic policy must carry NO Condition — EventBridge does not populate condition context on this path, so a guard here silently denies every page"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_kms_key.alerts[0].policy).Statement :
      !can(s.Condition)
      if try(s.Principal.Service, "") == "events.amazonaws.com"
    ])
    error_message = "the EventBridge grant on the alerts CMK must carry no Condition either — an unpopulated key fails closed and drops the message one layer down"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.alerts[0].policy).Statement :
      s
      if try(s.Principal.Service, "") == "events.amazonaws.com"
      && contains(s.Action, "kms:GenerateDataKey*")
    ]) == 1
    error_message = "the alerts CMK must admit events.amazonaws.com for kms:GenerateDataKey*, or an EventBridge publish to an SSE-KMS topic is dropped"
  }
}

# The eks-agent-platform tree reads every landing-zone value it needs through
# /eks-agent-platform/<cluster-name>/; its kill-switch component resolves these
# topic ARNs at plan time. Published in both modes off the same local, so a
# consumer wires against one interface whether the topics are local or central.
run "severity_topic_arns_are_published_to_the_ssm_contract" {
  command = plan

  assert {
    condition = alltrue([
      aws_ssm_parameter.alerts_critical_topic_arn.name == "/eks-agent-platform/development-platform/observability/alerts_critical_topic_arn",
      aws_ssm_parameter.alerts_warning_topic_arn.name == "/eks-agent-platform/development-platform/observability/alerts_warning_topic_arn",
      aws_ssm_parameter.alerts_info_topic_arn.name == "/eks-agent-platform/development-platform/observability/alerts_info_topic_arn",
    ])
    error_message = "the severity topic ARNs must be published under /eks-agent-platform/<cluster-name>/observability/ — the kill-switch component reads them from there"
  }
}

# --- create | adopt seam ----------------------------------------------------

# adopt mode builds no local topics or key, points the same alarms at the central topics, and
# re-exports them through sns_topic_arns — the definitions stay local, the destination moves.
run "adopt_mode_points_alarms_at_central_topics" {
  command = plan

  variables {
    observability_mode = "adopt"
    adopt_topic_arns = {
      critical = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-critical"
      warning  = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-warning"
      info     = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-info"
    }
  }

  assert {
    condition     = length(aws_sns_topic.critical) == 0 && length(aws_kms_key.alerts) == 0
    error_message = "adopt mode must build no local topics or alert key — the destination is central"
  }

  # The composite alarms (not the child alarms) carry the notification, so it's the
  # composites that must point at the central topics in adopt mode.
  assert {
    condition = contains(
      aws_cloudwatch_composite_alarm.cluster_health_critical[0].alarm_actions,
      "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-critical"
    )
    error_message = "adopt-mode critical composite must publish to the central critical topic"
  }

  assert {
    condition = contains(
      aws_cloudwatch_composite_alarm.cluster_health_degraded[0].alarm_actions,
      "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-warning"
    )
    error_message = "adopt-mode degraded composite must publish to the central warning topic"
  }

  assert {
    condition     = output.sns_topic_arns.critical == "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-critical"
    error_message = "sns_topic_arns must re-export the adopted central ARNs, the same shape as create mode"
  }
}

# --- composite rollup (fleet_alerting) ---------------------------------------

# The child metric alarms carry NO SNS action — they only compute state. This is the
# guarantee that N simultaneous firings can't each page: only the composite notifies.
run "child_alarms_carry_no_sns_action" {
  command = plan

  assert {
    condition = alltrue([
      for a in [
        aws_cloudwatch_metric_alarm.cluster_api_server_errors[0],
        aws_cloudwatch_metric_alarm.node_cpu_utilization[0],
        aws_cloudwatch_metric_alarm.node_memory_utilization[0],
        aws_cloudwatch_metric_alarm.cluster_failed_node_count[0],
      ] : try(length(a.alarm_actions), 0) == 0 && try(length(a.ok_actions), 0) == 0
    ])
    error_message = "child metric alarms must carry no alarm_actions/ok_actions — the composite is the only notification surface"
  }
}

# Each severity composite ORs exactly its children and carries one SNS action. The
# critical composite rolling up both critical signals is what makes a hard-down cluster
# page once rather than once per firing alarm.
run "composites_roll_up_their_children" {
  command = plan

  assert {
    condition = (
      strcontains(aws_cloudwatch_composite_alarm.cluster_health_critical[0].alarm_rule, "ALARM(\"development-platform-api-server-5xx\")")
      && strcontains(aws_cloudwatch_composite_alarm.cluster_health_critical[0].alarm_rule, "ALARM(\"development-platform-failed-nodes\")")
    )
    error_message = "critical composite must OR the api-server-5xx and failed-nodes child alarms"
  }

  assert {
    condition = (
      strcontains(aws_cloudwatch_composite_alarm.cluster_health_degraded[0].alarm_rule, "ALARM(\"development-platform-node-cpu-high\")")
      && strcontains(aws_cloudwatch_composite_alarm.cluster_health_degraded[0].alarm_rule, "ALARM(\"development-platform-node-memory-high\")")
    )
    error_message = "degraded composite must OR the cpu and memory child alarms"
  }

  assert {
    condition = (
      length(aws_cloudwatch_composite_alarm.cluster_health_critical[0].alarm_actions) == 1
      && length(aws_cloudwatch_composite_alarm.cluster_health_degraded[0].alarm_actions) == 1
    )
    error_message = "each composite must carry exactly one severity SNS action"
  }
}

# Every alarm and composite carries the standard fleet dimensions (Severity, ClusterName)
# as tags, so routing and rollup key on tags rather than on parsed alarm names.
run "alarms_carry_standard_severity_dimensions" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.cluster_api_server_errors[0].tags["Severity"] == "critical"
      && aws_cloudwatch_metric_alarm.cluster_api_server_errors[0].tags["ClusterName"] == "development-platform"
      && aws_cloudwatch_metric_alarm.node_cpu_utilization[0].tags["Severity"] == "warning"
      && aws_cloudwatch_composite_alarm.cluster_health_critical[0].tags["Severity"] == "critical"
      && aws_cloudwatch_composite_alarm.cluster_health_degraded[0].tags["Severity"] == "warning"
    )
    error_message = "fleet alarms and composites must carry the standard Severity + ClusterName dimensions as tags"
  }
}

# create mode rejects an adopt-mode input — a foreign-topic reference is meaningless when this
# component builds its own topics.
run "create_mode_rejects_adopt_topics" {
  command = plan

  variables {
    adopt_topic_arns = {
      critical = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-critical"
      warning  = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-warning"
      info     = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-info"
    }
  }

  expect_failures = [var.adopt_topic_arns]
}

# adopt mode requires all three severities — a partial set would leave some alarms with no
# destination.
run "adopt_mode_requires_all_severities" {
  command = plan

  variables {
    observability_mode = "adopt"
    adopt_topic_arns = {
      critical = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-critical"
    }
  }

  expect_failures = [var.adopt_topic_arns]
}

# adopt mode rejects local pager subscriptions — the central topics' subscriptions belong to
# their owner.
run "adopt_mode_rejects_local_email" {
  command = plan

  variables {
    observability_mode = "adopt"
    adopt_topic_arns = {
      critical = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-critical"
      warning  = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-warning"
      info     = "arn:aws:sns:us-east-1:777777777777:platform-fleet-alerts-info"
    }
    alert_email_endpoints = ["on-call@example.com"]
  }

  expect_failures = [var.alert_email_endpoints]
}

# Every alarm watches a metric that CloudWatch actually publishes under the
# ClusterName dimension alone. Container Insights publishes most of its metrics
# only with node- or pod-scoped dimension sets; an alarm keyed on ClusterName
# against one of those sits in INSUFFICIENT_DATA forever and its composite can
# never fire — a monitor that looks installed and monitors nothing.
#
# The metric names are pinned individually because the failure is not detectable
# from the alarm's own shape: an alarm named "-api-server-5xx" watched
# apiserver_request_total, the count of ALL API-server requests, which clears any
# 5xx threshold on a healthy cluster within seconds.
run "alarms_watch_cluster_scoped_metrics_that_exist" {
  command = plan

  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.cluster_api_server_errors[0].metric_name == "apiserver_request_total_5xx",
      aws_cloudwatch_metric_alarm.node_cpu_utilization[0].metric_name == "node_cpu_utilization",
      aws_cloudwatch_metric_alarm.node_memory_utilization[0].metric_name == "node_memory_utilization",
      aws_cloudwatch_metric_alarm.cluster_failed_node_count[0].metric_name == "cluster_failed_node_count",
    ])
    error_message = "an alarm watches a metric with no ClusterName-only rollup, or the api-server alarm regressed onto the total-request counter"
  }

  assert {
    condition = alltrue([
      for a in [
        aws_cloudwatch_metric_alarm.cluster_api_server_errors[0],
        aws_cloudwatch_metric_alarm.node_cpu_utilization[0],
        aws_cloudwatch_metric_alarm.node_memory_utilization[0],
        aws_cloudwatch_metric_alarm.cluster_failed_node_count[0],
      ] : length(a.dimensions) == 1 && try(a.dimensions["ClusterName"], "") == "development-platform"
    ])
    error_message = "every cluster-health alarm must key on ClusterName alone — a narrower dimension set makes it unmatchable at cluster scope"
  }
}

# A silent cluster must not read as a well cluster.
#
# Every metric this component alarms on is published by the
# amazon-cloudwatch-observability agent. CloudWatch's default for absent data is
# `missing`, which a composite alarm does not treat as ALARM — so an agent that
# stops publishing takes the liveness alarms to INSUFFICIENT_DATA and the critical
# composite goes quiet, at the moment it is most needed. The failure is invisible:
# the dashboard empties rather than reddens.
#
# The split is per-signal, not per-severity. Absence of a liveness datapoint is a
# fault; absence of a saturation datapoint says nothing about saturation, and
# paging on it would fire a second time for the same missing agent.
#
# Asserted because these are absence-by-default settings: delete either line and
# the old behaviour returns with nothing in the diff to notice.
run "missing_data_is_a_fault_on_liveness_and_ignored_on_saturation" {
  command = plan

  assert {
    condition = alltrue([
      for a in [
        aws_cloudwatch_metric_alarm.cluster_api_server_errors[0],
        aws_cloudwatch_metric_alarm.cluster_failed_node_count[0],
      ] : a.treat_missing_data == "breaching"
    ])
    error_message = "the liveness alarms (api-server 5xx, failed nodes) must set treat_missing_data = \"breaching\" — on CloudWatch's default the composite stays quiet exactly when the metric pipeline dies"
  }

  assert {
    condition = alltrue([
      for a in [
        aws_cloudwatch_metric_alarm.node_cpu_utilization[0],
        aws_cloudwatch_metric_alarm.node_memory_utilization[0],
      ] : a.treat_missing_data == "missing"
    ])
    error_message = "the saturation alarms must set treat_missing_data = \"missing\" — absent utilization data is not evidence of saturation, and breaching here would page a second time for the same dead agent"
  }
}

# The SLO half of the observability-slo standard.
#
# The fleet-alerting half (composites own the action, children stay actionless) is
# asserted above. This is the half that was absent: an objective, an error budget,
# and burn-rate alerting at the standard's four window pairs.
#
# What makes it worth asserting rather than trusting is that every part of it is
# quiet when wrong. A burn-rate pair whose composite ORs instead of ANDs pages on
# every spike; one that never rolls into a severity composite computes state
# nobody sees; a factor that drifts off the standard's value still produces a
# plausible-looking alarm. None of that surfaces at apply.
run "slo_burn_rate_pairs_match_the_standard" {
  command = plan

  # Four pairs, eight window alarms. The count is the assertion: a pair silently
  # dropped from the map is the shape this catches.
  assert {
    condition     = length(aws_cloudwatch_composite_alarm.slo_burn) == 4 && length(aws_cloudwatch_metric_alarm.slo_burn_window) == 8
    error_message = "the SLO must declare the standard's four burn-rate window pairs, each as a long and a short window alarm"
  }

  # The standard's factors, keyed to their windows. A factor is what converts an
  # error ratio into "budget spent per window", so a wrong one is an alarm that
  # fires at the wrong spend rate while reading as correct.
  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.slo_burn_window["fast-long"].threshold == 14.4,
      aws_cloudwatch_metric_alarm.slo_burn_window["fast-short"].threshold == 14.4,
      aws_cloudwatch_metric_alarm.slo_burn_window["quick-long"].threshold == 6,
      aws_cloudwatch_metric_alarm.slo_burn_window["steady-long"].threshold == 3,
      aws_cloudwatch_metric_alarm.slo_burn_window["slow-long"].threshold == 1,
    ])
    error_message = "burn-rate factors must be the standard's 14.4 / 6 / 3 / 1 for the 1h / 6h / 1d / 3d windows"
  }

  # Multi-window means AND. An OR here turns the whole mechanism into the
  # instantaneous-error-ratio alerting the standard's do_not list rejects, and it
  # would look identical in the console.
  assert {
    condition = alltrue([
      for c in values(aws_cloudwatch_composite_alarm.slo_burn) :
      strcontains(c.alarm_rule, " AND ") && !strcontains(c.alarm_rule, " OR ")
    ])
    error_message = "a burn-rate composite must AND its long and short window alarms — an OR fires on a one-off spike, which is the flapping the multi-window method exists to suppress"
  }

  # Children compute, composites notify. The same contract the cluster-health
  # rollups hold, extended to the pairs.
  assert {
    condition = alltrue([
      for a in values(aws_cloudwatch_metric_alarm.slo_burn_window) : length(a.alarm_actions) == 0
    ])
    error_message = "burn-rate window alarms must carry NO SNS action — they exist to compute state, and the per-severity composites own the notification so a burning cluster pages once"
  }

  assert {
    condition = alltrue([
      for c in values(aws_cloudwatch_composite_alarm.slo_burn) : length(c.alarm_actions) == 0
    ])
    error_message = "a burn-rate PAIR composite must also stay actionless — it rolls up into the per-severity cluster composite, which is the single notification surface"
  }

  # The rollup is what makes the pairs reachable. Without it they are eight alarms
  # and four composites nobody is subscribed to.
  assert {
    condition = (
      strcontains(aws_cloudwatch_composite_alarm.cluster_health_critical[0].alarm_rule, aws_cloudwatch_composite_alarm.slo_burn["fast"].alarm_name)
      && strcontains(aws_cloudwatch_composite_alarm.cluster_health_critical[0].alarm_rule, aws_cloudwatch_composite_alarm.slo_burn["quick"].alarm_name)
    )
    error_message = "the page-tier burn-rate pairs (1h/5m and 6h/30m) must roll into the critical composite, or a budget burning at 14.4x notifies nobody"
  }

  assert {
    condition = (
      strcontains(aws_cloudwatch_composite_alarm.cluster_health_degraded[0].alarm_rule, aws_cloudwatch_composite_alarm.slo_burn["steady"].alarm_name)
      && strcontains(aws_cloudwatch_composite_alarm.cluster_health_degraded[0].alarm_rule, aws_cloudwatch_composite_alarm.slo_burn["slow"].alarm_name)
    )
    error_message = "the ticket-tier burn-rate pairs (1d/2h and 3d/6h) must roll into the degraded composite"
  }

  # The SLI is the ratio the objective is defined over. Reading the wrong
  # numerator — apiserver_request_total in place of the 5xx counter — yields a
  # burn rate near 1.0 on a perfectly healthy cluster.
  assert {
    condition = alltrue([
      for a in values(aws_cloudwatch_metric_alarm.slo_burn_window) : anytrue([
        for q in a.metric_query : try(q.metric[0].metric_name, "") == "apiserver_request_total_5xx"
        ]) && anytrue([
        for q in a.metric_query : try(q.metric[0].metric_name, "") == "apiserver_request_total"
      ])
    ])
    error_message = "every burn-rate alarm must compute its ratio from apiserver_request_total_5xx over apiserver_request_total — the two series the enhanced Container Insights control-plane set publishes and the API-server alarm already reads"
  }

  # No traffic is not a burn. Breaching here would page on an idle cluster, and
  # the liveness alarms already carry the cluster-unreachable case.
  assert {
    condition = alltrue([
      for a in values(aws_cloudwatch_metric_alarm.slo_burn_window) : a.treat_missing_data == "notBreaching"
    ])
    error_message = "burn-rate alarms must treat missing data as notBreaching — no requests means no errors means no burn, and the unreachable-cluster case belongs to the liveness alarms"
  }
}

# The 3-day window is the one the platform cannot express directly: CloudWatch
# caps a metric period at 86400s. It is rendered as three consecutive daily
# evaluations, which requires the burn to persist rather than to average out —
# strictly less likely to fire than the standard's 3-day ratio, never more.
run "three_day_window_is_rendered_as_consecutive_daily_evaluations" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.slo_burn_window["slow-long"].evaluation_periods == 3
      && aws_cloudwatch_metric_alarm.slo_burn_window["slow-long"].datapoints_to_alarm == 3
    )
    error_message = "the 3d window must require 3 of 3 daily datapoints — with datapoints_to_alarm below evaluation_periods it fires on a single bad day, which is a different and much noisier alert than the standard's"
  }
}
