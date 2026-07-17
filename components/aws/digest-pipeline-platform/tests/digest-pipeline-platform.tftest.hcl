# Unit tests for digest-pipeline-platform's bucket in-transit hardening. This
# component owns two buckets — the voice-baseline corpus and the raw-aggregations
# debug snapshots — and each carries its own resource policy that seeds the
# DenyInsecureTransport baseline. The contract under test: BOTH bucket policies deny
# every non-TLS request (s3:* when aws:SecureTransport=false). Drop the statement on
# either and that bucket is reachable over plaintext HTTP.
#
# PROVIDER STRATEGY (B, real credential-less provider). A mock provider can't
# synthesize the SES identity's purely-computed dkim_signing_attributes block, which
# an output indexes into ([0].tokens) — under a mock it renders as an empty list and
# the plan errors. A real provider with skip_* flags (no creds, no network) leaves
# computed values UNKNOWN instead, so that index yields unknown (harmless) rather than
# failing. override_data resolves the two network-backed data sources (caller_identity
# and the operator-created tenant role the Pod Identity association reads); the two S3
# bucket ARNs are pinned with override_resource so the bucket policies — which embed
# those ARNs — render as known JSON the assertions can decode.

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/test"
    user_id    = "AIDTEST"
  }
}

override_data {
  target = module.platform_app.data.aws_iam_role.tenant
  values = {
    arn = "arn:aws:iam::123456789012:role/mock-tenant"
  }
}

override_resource {
  target = aws_s3_bucket.voice_baseline
  values = {
    arn = "arn:aws:s3:::test-voice-baseline"
    id  = "test-voice-baseline"
  }
}

override_resource {
  target = aws_s3_bucket.raw_aggregations
  values = {
    arn = "arn:aws:s3:::test-raw-aggregations"
    id  = "test-raw-aggregations"
  }
}

variables {
  environment        = "development"
  region             = "us-west-2"
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  cluster_sg_id      = "sg-0123456789abcdef0"
  cluster_name       = "development-platform"
  ses_sending_domain = "digest.example.com"
}

run "both_buckets_deny_insecure_transport" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.voice_baseline.policy).Statement :
      s if try(s.Sid, "") == "DenyInsecureTransport"
      && try(s.Effect, "") == "Deny"
      && try(s.Action, "") == "s3:*"
      && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"
    ]) == 1
    error_message = "voice-baseline bucket policy must Deny s3:* when aws:SecureTransport=false"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.raw_aggregations.policy).Statement :
      s if try(s.Sid, "") == "DenyInsecureTransport"
      && try(s.Effect, "") == "Deny"
      && try(s.Action, "") == "s3:*"
      && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"
    ]) == 1
    error_message = "raw-aggregations bucket policy must Deny s3:* when aws:SecureTransport=false"
  }
}
