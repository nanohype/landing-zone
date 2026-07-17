# Unit tests for fleet-hub — the management-account state bucket that holds the
# OpenTofu state of every vended cluster. That state is the highest-value data in
# the fleet's blast radius, so this suite guards its at-rest and in-transit
# hardening: the bucket is SSE-KMS with a dedicated CMK (not SSE-S3), and its
# bucket policy denies any non-TLS request. Flip the encryption back to AES256 or
# drop the TLS deny and cluster state is readable with a weaker key or over
# plaintext — a silent regression this suite bites.
#
# Runs at command = plan against a mocked AWS provider. The hub trust is a
# data.aws_iam_policy_document (mangled by mock_provider), so it's handed a valid
# empty JSON stub purely to unblock the plan — it is not asserted. The bucket SSE
# config and bucket policy are direct resources / jsonencode, so they render for
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
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-west-2:123456789012:key/fleet-state"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/eks-fleet-crossplane"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/eks-fleet/eks-fleet-hub-boundary"
    }
  }
}

variables {
  environment       = "development"
  region            = "us-west-2"
  team              = "platform"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/TEST"
  oidc_issuer       = "https://oidc.eks.us-west-2.amazonaws.com/id/TEST"
  state_bucket_name = "test-fleet-state"
}

# The state bucket is SSE-KMS with the dedicated CMK — not SSE-S3. rule and
# apply_server_side_encryption_by_default are sets, so iterate them.
run "state_bucket_is_sse_kms" {
  command = plan

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.fleet_state.rule : anytrue([
        for d in r.apply_server_side_encryption_by_default :
        d.sse_algorithm == "aws:kms"
        && d.kms_master_key_id == "arn:aws:kms:us-west-2:123456789012:key/fleet-state"
      ])
    ])
    error_message = "fleet state bucket must use aws:kms SSE referencing the dedicated CMK ARN, not AES256"
  }
}

# The bucket policy denies every non-TLS request (aws:SecureTransport=false).
run "state_bucket_denies_insecure_transport" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.fleet_state.policy).Statement :
      s if try(s.Sid, "") == "DenyInsecureTransport"
      && try(s.Effect, "") == "Deny"
      && try(s.Action, "") == "s3:*"
      && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"
    ]) == 1
    error_message = "fleet state bucket policy must Deny s3:* when aws:SecureTransport=false"
  }
}

# The access-log sink grants only the S3 logging service principal, scoped to this
# source bucket + account, and denies non-TLS access to itself too.
run "state_log_bucket_scopes_log_delivery" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.fleet_state_logs.policy).Statement :
      s if try(s.Sid, "") == "AllowS3ServerAccessLogging"
      && try(s.Effect, "") == "Allow"
      && try(s.Principal.Service, "") == "logging.s3.amazonaws.com"
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "state log bucket must grant s3 logging delivery scoped by SourceAccount"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.fleet_state_logs.policy).Statement :
      s if try(s.Sid, "") == "DenyInsecureTransport" && try(s.Effect, "") == "Deny"
    ]) == 1
    error_message = "state log bucket policy must also Deny insecure transport"
  }
}
