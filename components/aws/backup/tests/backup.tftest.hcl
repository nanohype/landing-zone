# Unit tests for backup's notification-topic encryption. AWS Backup publishes vault
# events (failed/expired jobs) to the backup-notifications SNS topic; the contract
# under test is that topic is SSE-KMS with a DEDICATED customer-managed key — kept
# separate from the recovery-point vault CMK so the topic grant never widens the
# vault key — and that the dedicated notifications key's policy admits exactly the
# backup service principal, scoped to this account. Drop the encryption or swap in
# alias/aws/sns and the vault event is either sent in the clear or silently dropped.
#
# Runs at command = plan against a mocked AWS provider. The topic's kms_master_key_id
# is wired to the notifications key ARN and the key policy is jsonencode()'d, so both
# render for real at plan time.

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
  # The mock's random default isn't a parseable ARN; pin the keys + topic so the
  # backup vault (vault CMK ARN) and vault notifications (topic ARN) plan cleanly.
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
  # The backup plan/selection references the backup service IAM role ARN.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
}

variables {
  environment = "development"
  region      = "us-west-2"
  team        = "platform"
}

# The backup-notifications topic is SSE-KMS with its dedicated notifications CMK —
# not unencrypted, not alias/aws/sns, and not the vault recovery-point key.
run "backup_notifications_topic_is_sse_kms_with_dedicated_cmk" {
  command = plan

  assert {
    condition     = aws_sns_topic.backup_notifications.kms_master_key_id == aws_kms_key.notifications.arn
    error_message = "backup-notifications topic must be SSE-KMS referencing its dedicated notifications CMK ARN (never unencrypted, alias/aws/sns, or the vault key)"
  }
}

# The dedicated notifications CMK's policy admits the AWS Backup publisher,
# SourceAccount-scoped.
run "backup_notifications_key_admits_backup_publisher" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.notifications.policy).Statement :
      s if try(s.Principal.Service, "") == "backup.amazonaws.com"
      && contains(try(tolist(s.Action), [s.Action]), "kms:GenerateDataKey*")
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "backup-notifications CMK policy must admit backup.amazonaws.com for kms:GenerateDataKey*, scoped by aws:SourceAccount"
  }
}
