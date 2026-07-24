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
      arn = "arn:aws:kms:us-west-2:123456789012:key/mock"
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-west-2:123456789012:mock"
    }
  }
}

variables {
  environment  = "development"
  region       = "us-west-2"
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

# Each severity topic's resource policy grants CloudWatch publish scoped by
# aws:SourceAccount — the confused-deputy guard the sibling CMK policy already
# carries. Without it a service principal acting for any account could publish.
run "topic_policies_scope_publish_by_source_account" {
  command = plan

  assert {
    condition = alltrue([
      for p in [
        aws_sns_topic_policy.critical[0].policy,
        aws_sns_topic_policy.warning[0].policy,
        aws_sns_topic_policy.info[0].policy,
        ] : alltrue([
          for s in jsondecode(p).Statement :
          try(s.Principal.Service, "") == "cloudwatch.amazonaws.com"
          && s.Action == "SNS:Publish"
          && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
      ])
    ])
    error_message = "each of the critical/warning/info topic policies must grant SNS:Publish to cloudwatch.amazonaws.com scoped by aws:SourceAccount"
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
      critical = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-critical"
      warning  = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-warning"
      info     = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-info"
    }
  }

  assert {
    condition     = length(aws_sns_topic.critical) == 0 && length(aws_kms_key.alerts) == 0
    error_message = "adopt mode must build no local topics or alert key — the destination is central"
  }

  assert {
    condition = contains(
      aws_cloudwatch_metric_alarm.cluster_api_server_errors[0].alarm_actions,
      "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-critical"
    )
    error_message = "adopt-mode alarms must publish to the central critical topic"
  }

  assert {
    condition     = output.sns_topic_arns.critical == "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-critical"
    error_message = "sns_topic_arns must re-export the adopted central ARNs, the same shape as create mode"
  }
}

# create mode rejects an adopt-mode input — a foreign-topic reference is meaningless when this
# component builds its own topics.
run "create_mode_rejects_adopt_topics" {
  command = plan

  variables {
    adopt_topic_arns = {
      critical = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-critical"
      warning  = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-warning"
      info     = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-info"
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
      critical = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-critical"
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
      critical = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-critical"
      warning  = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-warning"
      info     = "arn:aws:sns:us-west-2:777777777777:platform-fleet-alerts-info"
    }
    alert_email_endpoints = ["on-call@example.com"]
  }

  expect_failures = [var.alert_email_endpoints]
}
