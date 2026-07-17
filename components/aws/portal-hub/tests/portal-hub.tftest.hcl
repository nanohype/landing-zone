# Unit tests for portal-hub — the management-account state bucket holding portal's
# OpenTofu state for every managed account. Same crown-jewel posture as fleet-hub:
# SSE-KMS with a dedicated CMK and a bucket policy denying non-TLS requests. A
# regression to AES256 or a dropped TLS deny would weaken the protection on
# portal's cross-account state.
#
# Runs at command = plan against a mocked AWS provider. The hub trust is a
# data.aws_iam_policy_document handed a valid empty JSON stub to unblock the plan
# (not asserted); the bucket SSE config and bucket policy render for real.

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
      arn = "arn:aws:kms:us-west-2:123456789012:key/portal-state"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/portal/development-portal-hub"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/portal/development-portal-hub-boundary"
    }
  }
}

variables {
  environment       = "development"
  team              = "platform"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/TEST"
  oidc_issuer       = "https://oidc.eks.us-west-2.amazonaws.com/id/TEST"
  state_bucket_name = "test-portal-state"
}

run "state_bucket_is_sse_kms" {
  command = plan

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.portal_state.rule : anytrue([
        for d in r.apply_server_side_encryption_by_default :
        d.sse_algorithm == "aws:kms"
        && d.kms_master_key_id == "arn:aws:kms:us-west-2:123456789012:key/portal-state"
      ])
    ])
    error_message = "portal state bucket must use aws:kms SSE referencing the dedicated CMK ARN, not AES256"
  }
}

run "state_bucket_denies_insecure_transport" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.portal_state.policy).Statement :
      s if try(s.Sid, "") == "DenyInsecureTransport"
      && try(s.Effect, "") == "Deny"
      && try(s.Action, "") == "s3:*"
      && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"
    ]) == 1
    error_message = "portal state bucket policy must Deny s3:* when aws:SecureTransport=false"
  }
}

run "state_log_bucket_scopes_log_delivery" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.portal_state_logs.policy).Statement :
      s if try(s.Sid, "") == "AllowS3ServerAccessLogging"
      && try(s.Principal.Service, "") == "logging.s3.amazonaws.com"
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "state log bucket must grant s3 logging delivery scoped by SourceAccount"
  }
}
