# Unit tests for cost's alert-topic encryption. AWS Cost Anomaly Detection
# publishes anomaly notifications to the cost-alerts SNS topic; the contract under
# test is that topic is SSE-KMS with a DEDICATED customer-managed key (not
# unencrypted, and not the AWS-managed alias/aws/sns — which cannot grant the
# costalerts service principal), and that the dedicated key's policy admits exactly
# that publisher, scoped to this account. Drop the encryption or swap in the managed
# key and the anomaly notification is either sent in the clear or silently dropped.
#
# Runs at command = plan against a mocked AWS provider. The topic's
# kms_master_key_id is wired to the key ARN and the key policy is jsonencode()'d, so
# both render for real at plan time.

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
  # The mock's random default isn't a parseable ARN; pin the key + topic so the
  # topic subscription and any downstream ARN-validated field plan cleanly.
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
  # The anomaly subscription's monitor_arn_list references the monitor's ARN.
  mock_resource "aws_ce_anomaly_monitor" {
    defaults = {
      arn = "arn:aws:ce::123456789012:anomalymonitor/mock"
    }
  }
}

variables {
  environment          = "development"
  region               = "us-west-2"
  team                 = "platform"
  monthly_budget_limit = 1000
  # A non-empty subscriber list so aws_ce_anomaly_subscription's required
  # subscriber block is present at plan.
  budget_alert_emails = ["ops@example.com"]
}

# The cost-alerts topic is SSE-KMS with its dedicated CMK — not unencrypted, not
# alias/aws/sns. Equality against the dedicated key's ARN bites both regressions:
# an unset kms_master_key_id (null) and a swap to the managed key.
run "cost_alerts_topic_is_sse_kms_with_dedicated_cmk" {
  command = plan

  assert {
    condition     = aws_sns_topic.cost_alerts.kms_master_key_id == aws_kms_key.cost_alerts.arn
    error_message = "cost-alerts topic must be SSE-KMS referencing its dedicated CMK ARN (never unencrypted or alias/aws/sns)"
  }
}

# The dedicated CMK's policy admits the Cost Anomaly publisher — the reason a
# dedicated key is required (the AWS-managed key cannot grant a service principal).
# The grant is SourceAccount-scoped so only this account's anomaly service can use it.
run "cost_alerts_key_admits_costalerts_publisher" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.cost_alerts.policy).Statement :
      s if try(s.Principal.Service, "") == "costalerts.amazonaws.com"
      && contains(try(tolist(s.Action), [s.Action]), "kms:GenerateDataKey*")
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "cost-alerts CMK policy must admit costalerts.amazonaws.com for kms:GenerateDataKey*, scoped by aws:SourceAccount"
  }
}
