# Unit tests for service-quotas' alert-topic encryption. CloudWatch quota-utilization
# alarms publish to the service-quota-alerts SNS topic; the contract under test is
# that topic is SSE-KMS with a DEDICATED customer-managed key (not unencrypted, and
# not the AWS-managed alias/aws/sns — which cannot grant the cloudwatch service
# principal), and that the dedicated key's policy admits exactly that publisher,
# scoped to this account. Drop the encryption or swap in the managed key and the
# alarm notification is either sent in the clear or silently dropped.
#
# Runs at command = plan against a mocked AWS provider. The topic's kms_master_key_id
# is wired to the key ARN and the key policy is jsonencode()'d, so both render for
# real at plan time.

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
  # CloudWatch alarm's alarm_actions (the topic ARN) plans cleanly.
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
  environment = "development"
  region      = "us-west-2"
  team        = "platform"
}

# The quota-alerts topic is SSE-KMS with its dedicated CMK — not unencrypted, not
# alias/aws/sns.
run "quota_alerts_topic_is_sse_kms_with_dedicated_cmk" {
  command = plan

  assert {
    condition     = aws_sns_topic.quota_alerts.kms_master_key_id == aws_kms_key.quota_alerts.arn
    error_message = "service-quota-alerts topic must be SSE-KMS referencing its dedicated CMK ARN (never unencrypted or alias/aws/sns)"
  }
}

# The dedicated CMK's policy admits the CloudWatch alarm publisher, SourceAccount-scoped.
run "quota_alerts_key_admits_cloudwatch_publisher" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.quota_alerts.policy).Statement :
      s if try(s.Principal.Service, "") == "cloudwatch.amazonaws.com"
      && contains(try(tolist(s.Action), [s.Action]), "kms:GenerateDataKey*")
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "service-quota-alerts CMK policy must admit cloudwatch.amazonaws.com for kms:GenerateDataKey*, scoped by aws:SourceAccount"
  }
}
