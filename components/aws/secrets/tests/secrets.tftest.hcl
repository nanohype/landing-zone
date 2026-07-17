# Unit tests for secrets — the platform Secrets Manager CMK. The security contract
# under test: the CMK's service grants are confined to THIS account. The
# AllowSecretsManagerService grant is a confused-deputy surface — without an
# aws:SourceAccount condition, Secrets Manager acting on behalf of ANY account
# could decrypt/GenerateDataKey with this key. The AllowBedrock sibling already
# carries the guard; this proves the SecretsManager grant reached parity.
#
# Runs at command = plan against a mocked AWS provider. aws_caller_identity is
# mocked so account-qualified values resolve; the key policy is built with
# jsonencode() inline, so its content is REAL and known at plan time. Assertions
# are STRUCTURAL — statements located by Sid, conditions checked by key.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDTEST"
    }
  }
}

variables {
  environment  = "development"
  region       = "us-west-2"
  cluster_name = "development-platform"
  team         = "platform"
}

# The SecretsManager service grant must be Allow, cover decrypt + data-key, and be
# confined to aws:SourceAccount == this account. Dropping the condition (or
# widening the account) fails this exactly.
run "secretsmanager_grant_is_account_scoped" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.secrets.policy).Statement :
      s if try(s.Sid, "") == "AllowSecretsManagerService"
      && try(s.Effect, "") == "Allow"
      && contains(try(s.Action, []), "kms:Decrypt")
      && contains(try(s.Action, []), "kms:GenerateDataKey")
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "KMS 'AllowSecretsManagerService' must be Allow and confined to aws:SourceAccount == this account (confused-deputy guard)"
  }
}
