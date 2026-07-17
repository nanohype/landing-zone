# Unit tests for incident-response-platform's audit-bucket in-transit hardening.
# The audit archive holds postmortem PDFs and incident timelines beyond the DDB
# TTL window; this component owns the bucket's resource policy, which seeds the
# DenyInsecureTransport baseline. The contract under test: the bucket policy denies
# every non-TLS request (s3:* when aws:SecureTransport=false). Drop that statement
# and the archive is reachable over plaintext HTTP.
#
# Runs at command = plan against a mocked AWS provider. The bucket policy is
# jsonencode()'d, so it renders for real at plan time; aws_iam_role is pinned to a
# valid ARN so the tenant Pod Identity association plans.

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
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
  # The tenant Pod Identity association reads the operator-created tenant role via a
  # data source; pin it to a valid ARN so aws_eks_pod_identity_association plans.
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-tenant"
    }
  }
}

variables {
  environment  = "development"
  region       = "us-west-2"
  cluster_name = "development-platform"
}

run "audit_bucket_denies_insecure_transport" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.audit.policy).Statement :
      s if try(s.Sid, "") == "DenyInsecureTransport"
      && try(s.Effect, "") == "Deny"
      && try(s.Action, "") == "s3:*"
      && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"
    ]) == 1
    error_message = "audit bucket policy must Deny s3:* when aws:SecureTransport=false"
  }
}
