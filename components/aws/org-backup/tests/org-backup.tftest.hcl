# Unit tests for org-backup — the org-level backup floor. The contracts under test: the
# generated Organizations BACKUP_POLICY document has the shape AWS requires (plans → rules →
# selections with @@assign operators), it selects by the BackupPolicy tag, it copies to the
# central vault when one is wired, and the retention validations reject an invalid lifecycle.
#
# Runs at command = plan against a mocked provider. The policy content is jsonencode()'d from
# static inputs, so it renders for real at plan time.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }
  mock_resource "aws_organizations_policy" {
    defaults = {
      id  = "p-mock000000"
      arn = "arn:aws:organizations::123456789012:policy/o-mock/backup_policy/p-mock000000"
    }
  }
}

variables {
  environment = "org"
  region      = "us-west-2"
  team        = "sre"
  target_ids  = ["r-mock"]
  backup_policy = {
    copy_to_central_vault_arn = "arn:aws:backup:us-east-1:666666666666:backup-vault:production-central-backup-vault"
  }
}

# The generated document is a valid BACKUP_POLICY: one plan, one rule with an @@assign
# schedule, and a tag selection keyed on BackupPolicy.
run "policy_has_backup_plan_shape" {
  command = plan

  assert {
    condition     = jsondecode(aws_organizations_policy.backup.content).plans["org-baseline"].rules["daily"].schedule_expression["@@assign"] == "cron(0 5 ? * * *)"
    error_message = "the backup policy must carry a daily rule with an @@assign schedule expression"
  }

  assert {
    condition     = jsondecode(aws_organizations_policy.backup.content).plans["org-baseline"].selections.tags["BackupPolicy-selection"].tag_key["@@assign"] == "BackupPolicy"
    error_message = "the selection must match resources by the BackupPolicy tag"
  }

  assert {
    condition     = aws_organizations_policy.backup.type == "BACKUP_POLICY"
    error_message = "the policy must be of type BACKUP_POLICY"
  }
}

# When a central vault is wired, the rule copies each recovery point to it.
run "policy_copies_to_central_vault" {
  command = plan

  assert {
    condition     = contains(keys(jsondecode(aws_organizations_policy.backup.content).plans["org-baseline"].rules["daily"].copy_actions), "arn:aws:backup:us-east-1:666666666666:backup-vault:production-central-backup-vault")
    error_message = "with copy_to_central_vault_arn set, the rule must carry a copy_action keyed on the central vault ARN"
  }
}

# No central vault wired: no copy action (the floor still backs up locally).
run "policy_omits_copy_without_central_vault" {
  command = plan

  variables {
    backup_policy = {}
  }

  assert {
    condition     = !can(jsondecode(aws_organizations_policy.backup.content).plans["org-baseline"].rules["daily"].copy_actions)
    error_message = "without a central vault, the rule must not carry a copy_action"
  }
}

# The cold-storage lifecycle rule is enforced: AWS Backup requires 90 days in cold storage
# before deletion, so delete_after_days must be at least cold_storage_after_days + 90.
run "rejects_invalid_cold_storage_lifecycle" {
  command = plan

  variables {
    backup_policy = {
      cold_storage_after_days = 30
      delete_after_days       = 60
    }
  }

  expect_failures = [var.backup_policy]
}

# A delegated-admin registration without an account id is rejected at the boundary.
run "rejects_delegated_admin_without_account" {
  command = plan

  variables {
    register_delegated_admin   = true
    delegated_admin_account_id = ""
  }

  expect_failures = [var.delegated_admin_account_id]
}
