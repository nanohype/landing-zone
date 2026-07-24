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
  # The restore testing plan's include_vaults is ARN-validated at plan; pin the vault ARN so
  # the random mock default doesn't fail the parse.
  mock_resource "aws_backup_vault" {
    defaults = {
      arn = "arn:aws:backup:us-west-2:123456789012:backup-vault:mock"
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

# The local vault lock is GOVERNANCE mode, never COMPLIANCE. Governance omits
# changeable_for_days, keeping the lock removable by an explicit override; COMPLIANCE mode
# (set by changeable_for_days) is immutable after its grace period — the irreversible door
# the estate already got burned by. This is the acceptance criterion "no vault in COMPLIANCE
# mode without a named regulation."
run "vault_lock_is_governance_not_compliance" {
  command = plan

  variables {
    enable_vault_lock = true
  }

  assert {
    condition     = aws_backup_vault_lock_configuration.this[0].changeable_for_days == null
    error_message = "the local vault lock must be GOVERNANCE mode (changeable_for_days unset), never COMPLIANCE"
  }
}

# When a central vault is wired, every plan rule copies its recovery points to it — the
# resilience win that moves the durable copy out of the account holding the data.
run "plan_rules_copy_to_central_vault" {
  command = plan

  variables {
    central_vault_arn = "arn:aws:backup:us-east-1:666666666666:backup-vault:development-central-backup-vault"
  }

  assert {
    condition = alltrue([
      for plan in aws_backup_plan.this : anytrue([
        for rule in plan.rule : anytrue([
          for ca in rule.copy_action :
          ca.destination_vault_arn == "arn:aws:backup:us-east-1:666666666666:backup-vault:development-central-backup-vault"
        ])
      ])
    ])
    error_message = "with central_vault_arn set, every backup plan rule must carry a copy_action to the central vault"
  }
}

# No central vault and no per-plan override: no copy action is emitted — the shape before
# central backup is stood up.
run "no_copy_action_without_central_vault" {
  command = plan

  assert {
    condition = alltrue([
      for plan in aws_backup_plan.this : alltrue([
        for rule in plan.rule : length(rule.copy_action) == 0
      ])
    ])
    error_message = "without a central vault or a per-plan override, no copy_action should be emitted"
  }
}

# Restore testing is off by default (it provisions real resources), and when enabled it
# creates a plan plus one selection per protected-resource type, each testing all recovery
# points of that type.
run "restore_testing_absent_by_default" {
  command = plan

  assert {
    condition     = length(aws_backup_restore_testing_plan.this) == 0
    error_message = "restore testing must be off by default"
  }
}

run "restore_testing_created_when_enabled" {
  command = plan

  variables {
    restore_testing = {
      enabled        = true
      resource_types = ["Aurora", "DynamoDB"]
    }
  }

  assert {
    condition     = length(aws_backup_restore_testing_plan.this) == 1
    error_message = "restore testing plan must be created when restore_testing.enabled is true"
  }

  assert {
    condition     = length(aws_backup_restore_testing_selection.this) == 2
    error_message = "one restore testing selection per resource type"
  }

  assert {
    condition = alltrue([
      for s in aws_backup_restore_testing_selection.this : contains(s.protected_resource_arns, "*")
    ])
    error_message = "each restore testing selection must test all protected resources of its type (protected_resource_arns = [\"*\"])"
  }
}
