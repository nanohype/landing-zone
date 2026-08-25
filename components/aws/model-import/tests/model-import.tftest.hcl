# Unit tests for model-import — the S3 staging bucket open-weight model files land
# in, and the role Bedrock assumes to read them during a CreateModelImportJob.
#
# The component's whole safety argument is that this role cannot be used at
# inference time and cannot be assumed by anything but a Bedrock import job in
# this account. That argument rests on two condition keys and nothing else, so
# they are what this suite asserts:
#
#   1. aws:SourceAccount pins the assumption to this account. Without it, the
#      Bedrock service principal acting for ANY account can assume the role.
#   2. aws:SourceArn pins it to model-import-job/*. Without it the role is
#      assumable by any Bedrock activity in the account, which is precisely the
#      "cannot be assumed at inference time" claim the header makes.
#
# Plus the two properties that make the staged weights safe to leave sitting
# there: the grant is read-only, and the bucket refuses plaintext transport.
#
# Everything under assertion is built with jsonencode() inline, so a mock provider
# renders it for real.

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
}

variables {
  environment = "development"
  region      = "us-east-1"
  team        = "platform"
}

# INVARIANT 1 — the trust is pinned to a Bedrock IMPORT JOB in THIS account.
#
# Both keys, asserted individually. Either one alone leaves a real hole, and the
# policy reads as guarded with only one of them present.
run "trust_is_pinned_to_an_import_job_in_this_account" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.import.assume_role_policy).Statement :
      s if try(s.Effect, "") == "Allow"
      && try(s.Principal.Service, "") == "bedrock.amazonaws.com"
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
      && try(s.Condition.ArnEquals["aws:SourceArn"], "") == "arn:aws:bedrock:us-east-1:123456789012:model-import-job/*"
    ]) == 1
    error_message = "the import role's trust must carry BOTH aws:SourceAccount and an aws:SourceArn pinned to model-import-job/*. Without SourceAccount the Bedrock principal acting for any account can assume it; without SourceArn it is assumable by any Bedrock activity here, which contradicts the component's claim that it cannot be assumed at inference time"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.import.assume_role_policy).Statement) == 1
    error_message = "the import role's trust must carry exactly one statement; a second Allow widens it while the first still reads correct"
  }
}

# INVARIANT 2 — read-only on the staging bucket, and only this account's copy of
# it. aws:ResourceAccount is what stops a same-named bucket in another account
# from being read through this role.
run "grant_is_read_only_and_account_scoped" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.import_read_staging.policy).Statement : [
        for a in flatten([s.Action]) :
        can(regex(":(Get|List)", a))
      ]
    ]))
    error_message = "the Bedrock import grant must be read-only — it exists to read staged weights, and a write verb lets an import job mutate the staging area it reads from"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.import_read_staging.policy).Statement :
      s if try(s.Sid, "") == "ReadStagingWeights"
      && try(s.Condition.StringEquals["aws:ResourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "the read grant must carry aws:ResourceAccount — without it a same-named bucket in another account is readable through this role"
  }
}

# INVARIANT 3 — the staged weights refuse plaintext transport. Model weights are
# large and slow to move, which makes an unencrypted transfer both likelier to be
# observed and more expensive to redo.
run "bucket_denies_insecure_transport" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.staging.policy).Statement :
      s if try(s.Sid, "") == "DenyInsecureTransport"
      && try(s.Effect, "") == "Deny"
      && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"
    ]) == 1
    error_message = "the staging bucket must Deny every action over plaintext transport"
  }
}

# Public access is blocked on all four axes. Three of four reads as configured and
# leaves the fourth open, which is why each is asserted rather than the block's
# presence.
run "staging_bucket_is_not_public" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_public_access_block.staging.block_public_acls
      && aws_s3_bucket_public_access_block.staging.block_public_policy
      && aws_s3_bucket_public_access_block.staging.ignore_public_acls
      && aws_s3_bucket_public_access_block.staging.restrict_public_buckets
    )
    error_message = "all four public-access-block axes must be true on the staging bucket; three of four reads as configured and leaves the fourth open"
  }
}
