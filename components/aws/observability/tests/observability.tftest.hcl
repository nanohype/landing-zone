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

# All three severity topics are SSE-KMS with the dedicated alerts CMK.
run "all_alert_topics_are_sse_kms_with_dedicated_cmk" {
  command = plan

  assert {
    condition = (
      aws_sns_topic.critical.kms_master_key_id == aws_kms_key.alerts.arn
      && aws_sns_topic.warning.kms_master_key_id == aws_kms_key.alerts.arn
      && aws_sns_topic.info.kms_master_key_id == aws_kms_key.alerts.arn
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
      for s in jsondecode(aws_kms_key.alerts.policy).Statement :
      s if try(s.Principal.Service, "") == "cloudwatch.amazonaws.com"
      && contains(try(tolist(s.Action), [s.Action]), "kms:GenerateDataKey*")
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "alerts CMK policy must admit cloudwatch.amazonaws.com for kms:GenerateDataKey*, scoped by aws:SourceAccount"
  }
}
