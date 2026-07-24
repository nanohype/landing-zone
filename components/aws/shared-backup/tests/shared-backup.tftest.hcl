# Unit tests for shared-backup — the central backup vault owner. The contracts under test:
# the vault lock is GOVERNANCE (never the irreversible COMPLIANCE door), the vault CMK is
# multi-region so a cross-region restore can decrypt, and both the CMK policy and the vault
# access policy bound their wildcard principal by aws:PrincipalOrgID so exactly this
# organization — and no external account — can copy recovery points in.
#
# Runs at command = plan against a mocked AWS provider. Every policy is jsonencode()'d from
# static inputs, so it renders for real at plan time.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "666666666666"
      arn        = "arn:aws:iam::666666666666:user/test"
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
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:666666666666:key/mock"
    }
  }
}

variables {
  environment     = "development"
  region          = "us-east-1"
  team            = "sre"
  organization_id = "o-abcdef1234"
}

# The central vault lock is GOVERNANCE mode: changeable_for_days is unset. COMPLIANCE mode is
# immutable after its grace period and unremovable by anyone including root — the one-way door
# the estate already paid tuition on. This is the acceptance criterion "no vault in COMPLIANCE
# mode without a named regulation."
run "central_vault_lock_is_governance" {
  command = plan

  assert {
    condition     = aws_backup_vault_lock_configuration.central.changeable_for_days == null
    error_message = "the central vault lock must be GOVERNANCE mode (changeable_for_days unset), never COMPLIANCE"
  }
}

# The vault CMK is multi-region so a recovery-region replica can decrypt a cross-region
# restore — the first key region-model R5 says has to be multi-region.
run "central_vault_key_is_multi_region" {
  command = plan

  assert {
    condition     = aws_kms_key.central.multi_region == true
    error_message = "the central vault CMK must be multi-region so a cross-region restore can decrypt"
  }
}

# Every wildcard-principal statement in the CMK policy is bounded by aws:PrincipalOrgID: no
# statement admits a bare "*" without the org guard, so no external account can use the key.
run "central_key_policy_is_org_scoped" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_kms_key.central.policy).Statement :
      try(s.Principal, "") != "*" || try(s.Condition.StringEquals["aws:PrincipalOrgID"], "") == "o-abcdef1234"
    ])
    error_message = "every wildcard-principal statement in the central CMK policy must be bounded by aws:PrincipalOrgID"
  }
}

# The vault access policy admits backup:CopyIntoBackupVault, scoped to the organization.
run "central_vault_policy_admits_org_copy" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_backup_vault_policy.central.policy).Statement :
      s if contains(try(tolist(s.Action), [s.Action]), "backup:CopyIntoBackupVault")
      && try(s.Condition.StringEquals["aws:PrincipalOrgID"], "") == "o-abcdef1234"
    ]) == 1
    error_message = "the vault access policy must admit backup:CopyIntoBackupVault scoped by aws:PrincipalOrgID"
  }
}

# A malformed organization id is rejected at the variable boundary — an unscoped or typo'd
# org id would silently widen (or void) the cross-account copy grant.
run "rejects_malformed_organization_id" {
  command = plan

  variables {
    organization_id = "not-an-org-id"
  }

  expect_failures = [var.organization_id]
}
