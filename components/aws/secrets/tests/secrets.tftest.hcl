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

# ─────────────────────── the data/logs key split ───────────────────────
#
# var.separate_logs_key decides whether one key or two back the platform. The thing
# worth testing is not that a second key appears — it is WHERE each service grant
# lands, because a separation that leaves the log-path grants on the secrets key too
# reads as a boundary and enforces nothing.
#
# Assertions are over policy CONTENT, which jsonencode() makes real at plan time.
# Deliberately not over key ARNs: tofu generates mock values per ATTRIBUTE, so both
# keys' .arn resolve to the same string under mock_provider and any identity
# assertion would pass without testing anything. Where identity IS the subject (the
# output wiring, below), override_resource supplies distinct sentinels.

run "shared_is_the_default_and_one_key_carries_every_grant" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.secrets.policy).Statement :
      s if contains(["AllowCloudWatchLogs", "AllowBedrock"], try(s.Sid, ""))
    ]) == 2
    error_message = "with separate_logs_key unset the secrets key must carry BOTH log-path grants — a log group or Bedrock delivery pointed at kms_key_arn has no other key to use"
  }

  assert {
    condition     = length(aws_kms_key.logs) == 0
    error_message = "no second key may be minted unless separate_logs_key is set — an unused CMK is a monthly charge and an audit finding for a boundary nobody asked for"
  }
}

run "separating_moves_the_log_grants_off_the_secrets_key" {
  command = plan

  variables {
    separate_logs_key = true
  }

  # The half that makes the separation real. If these grants stayed, a log group could
  # encrypt under the secrets key and the "boundary" would be decoration.
  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.secrets.policy).Statement :
      s if contains(["AllowCloudWatchLogs", "AllowBedrock"], try(s.Sid, ""))
    ]) == 0
    error_message = "separating the logs key must REMOVE the log-path grants from the secrets key; leaving them lets a log group encrypt with either key, which is the appearance of a boundary and none of the substance"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.secrets.policy).Statement :
      s if try(s.Sid, "") == "AllowSecretsManagerService"
    ]) == 1
    error_message = "the secrets key must keep its Secrets Manager grant when the logs key separates — moving it would break every secret in the account"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.logs[0].policy).Statement :
      s if contains(["AllowCloudWatchLogs", "AllowBedrock"], try(s.Sid, ""))
    ]) == 2
    error_message = "the separated logs key must carry BOTH log-path grants — CloudWatch Logs for log groups and Bedrock for invocation-log delivery to S3"
  }

  # Root delegation is what lets IAM policies grant on the key at all. A logs key
  # without it is unusable by every principal in the account.
  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.logs[0].policy).Statement :
      s if try(s.Sid, "") == "EnableRootAccount"
    ]) == 1
    error_message = "the logs key must delegate to the account root, or no IAM policy can grant use of it"
  }

  # The logs key must NOT become a second secrets key.
  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.logs[0].policy).Statement :
      s if try(s.Sid, "") == "AllowSecretsManagerService"
    ]) == 0
    error_message = "the logs key must not carry the Secrets Manager grant — two keys that can both decrypt secrets is one key with extra steps"
  }

  assert {
    condition     = aws_kms_alias.logs[0].name == "alias/development-platform-logs"
    error_message = "the separated logs key must be aliased <environment>-platform-logs so an operator reading the console can tell the two keys apart"
  }
}

# The output is the whole consumer contract, and it is the one assertion where key
# IDENTITY is the subject rather than policy content — so both keys are overridden
# with distinct sentinel ARNs. Without the overrides the mock provider hands both
# keys the same generated arn and this passes no matter which one is wired.
run "the_logs_output_follows_the_flag" {
  command = plan

  variables {
    separate_logs_key = true
  }

  override_resource {
    target = aws_kms_key.secrets
    values = {
      arn = "arn:aws:kms:us-west-2:123456789012:key/SENTINEL-SECRETS"
    }
  }

  override_resource {
    target = aws_kms_key.logs
    values = {
      arn = "arn:aws:kms:us-west-2:123456789012:key/SENTINEL-LOGS"
    }
  }

  assert {
    condition     = output.logs_kms_key_arn == "arn:aws:kms:us-west-2:123456789012:key/SENTINEL-LOGS"
    error_message = "logs_kms_key_arn must resolve to the LOGS key when separated — publishing the secrets key here silently encrypts every log group under the data key, which is the exact posture the separation was set to end"
  }

  assert {
    condition     = output.kms_key_arn == "arn:aws:kms:us-west-2:123456789012:key/SENTINEL-SECRETS"
    error_message = "kms_key_arn must stay the SECRETS key when separated — repointing it at the logs key would re-encrypt platform data under the key the log readers hold"
  }
}

# Shared mode has to publish a usable logs handle too, or every consumer branches.
run "the_logs_output_is_the_secrets_key_when_shared" {
  command = plan

  override_resource {
    target = aws_kms_key.secrets
    values = {
      arn = "arn:aws:kms:us-west-2:123456789012:key/SENTINEL-SECRETS"
    }
  }

  assert {
    condition     = output.logs_kms_key_arn == "arn:aws:kms:us-west-2:123456789012:key/SENTINEL-SECRETS"
    error_message = "logs_kms_key_arn must fall back to the secrets key when sharing — a null or absent handle forces every consumer to branch on the mode, which is how one of them ends up branching wrong"
  }
}
