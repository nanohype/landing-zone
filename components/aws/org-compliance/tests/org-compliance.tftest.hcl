# org-compliance — audit-guardrail invariants
# =============================================================================
# These runs guard the ALWAYS-ON audit guardrails that make this account
# forensically trustworthy. Each asserted value is load-bearing: if it silently
# flips, an entire class of activity stops being recorded, stops being
# tamper-evident, or stops being confined to this account — and nobody notices
# until they need the logs and they aren't there.
#
# WHY THESE, AND WHY STRUCTURAL:
#   * CloudTrail multi-region + include_global_service_events: a single-region
#     trail leaves every other region (and global services like IAM/STS)
#     completely unlogged. This is the classic "attacker operates in us-east-2
#     while you only watch us-east-1" blind spot.
#   * enable_log_file_validation: without it the CloudTrail digest chain is
#     gone, so log tampering/deletion is undetectable — the logs stop being
#     evidence.
#   * KMS key rotation + the CloudTrail encrypt grant's aws:SourceAccount
#     condition: the shared compliance key encrypts the trail and Config data.
#     The SourceAccount StringEquals is a confused-deputy guard — drop it and
#     cloudtrail.amazonaws.com acting for ANY account could use this key.
#   * Config recording_group all_supported + include_global_resource_types:
#     flip either off and configuration drift for whole resource classes
#     (IAM, security groups, S3, etc.) goes unrecorded.
#
# Assertions are STRUCTURAL — statements are located by Sid and their exact
# Effect/Condition are checked (never by list position), and resource booleans
# are checked by name — so a reorder is not a failure and a real weakening is.
#
# PROVIDER STRATEGY A: this component builds every policy with jsonencode()
# inline, so aws_kms_key.compliance.policy renders as REAL JSON at plan time
# under mock_provider. The only API-backed reads (aws_caller_identity /
# aws_region) are mocked so account-qualified values resolve. Direct resource
# attributes (aws_cloudtrail.org, aws_config_configuration_recorder.this)
# render concretely at plan regardless of mocking.
#
# NOTE / COVERAGE GAP: the CloudTrail & Config S3 *bucket* policies are passed
# into the terraform-aws-modules/s3-bucket module, which re-serializes them
# through data.aws_iam_policy_document.combined. mock_provider mangles that
# data source into a non-JSON stub, so the bucket policy content does NOT
# render at plan and is intentionally NOT asserted here (asserting a mocked
# stub would be theater). The trail-service confinement / TLS posture of the
# buckets is out of scope for this plan-time test.

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

  mock_data "aws_region" {
    defaults = {
      name        = "us-west-2"
      region      = "us-west-2"
      description = "US West (Oregon)"
      endpoint    = "ec2.us-west-2.amazonaws.com"
    }
  }

  # The s3-bucket module re-serializes our bucket policies through
  # data.aws_iam_policy_document.combined; mock_provider would hand that a
  # non-JSON stub and the provider's plan-time "policy is valid JSON" check
  # would abort the whole plan. Give every mocked policy-doc a valid (empty)
  # JSON body so the plan proceeds. We do NOT assert on these bucket policies
  # (see header COVERAGE GAP) — this only unblocks the plan.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # aws_iam_role.config[0].arn feeds aws_config_configuration_recorder.role_arn,
  # which the provider validates as an ARN at plan. A random mock string fails
  # that check, so pin a syntactically valid role ARN.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }

  # aws_kms_key.compliance.arn feeds aws_cloudtrail.org.kms_key_id, also ARN-
  # validated at plan. Pin a valid key ARN. This only sets the computed arn;
  # the key's policy and enable_key_rotation are configured inline and render
  # for real (they are what we assert on).
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-west-2:123456789012:key/mock-compliance-key"
    }
  }
}

variables {
  environment = "development"
  region      = "us-west-2"
  team        = "platform"

  # Drop the CloudWatch Logs delivery path: it creates a log group + role whose
  # mock-generated ARNs fail the provider's plan-time ARN validation and are
  # irrelevant to the audit invariants under test.
  enable_log_insights = false
}

# -----------------------------------------------------------------------------
# INVARIANT 1: the trail sees the whole account — every region + global services
# -----------------------------------------------------------------------------
run "cloudtrail_is_multi_region_and_global" {
  command = plan

  assert {
    condition     = aws_cloudtrail.org[0].is_multi_region_trail == true
    error_message = "CloudTrail must be a multi-region trail; a single-region trail leaves other regions unaudited"
  }

  assert {
    condition     = aws_cloudtrail.org[0].include_global_service_events == true
    error_message = "CloudTrail must include global service events (IAM/STS/etc.), else global-service activity is never logged"
  }
}

# -----------------------------------------------------------------------------
# INVARIANT 2: the trail is tamper-evident (log-file validation digest chain)
# -----------------------------------------------------------------------------
run "cloudtrail_log_file_validation_enabled" {
  command = plan

  assert {
    condition     = aws_cloudtrail.org[0].enable_log_file_validation == true
    error_message = "CloudTrail log-file validation must be enabled so log tampering/deletion is detectable"
  }

  # The trail must be encrypted at rest with a KMS key (the compliance key).
  # If kms_key_id is dropped the trail falls back to SSE-S3 and the CMK key
  # policy / rotation guarantees no longer protect the logs.
  assert {
    condition     = aws_cloudtrail.org[0].kms_key_id != null && aws_cloudtrail.org[0].kms_key_id != ""
    error_message = "CloudTrail must be KMS-encrypted (kms_key_id must reference the compliance CMK)"
  }
}

# -----------------------------------------------------------------------------
# INVARIANT 3: the shared compliance KMS key rotates AND its CloudTrail encrypt
# grant is confined to THIS account (confused-deputy guard).
# -----------------------------------------------------------------------------
run "kms_key_rotates_and_cloudtrail_grant_is_account_scoped" {
  command = plan

  assert {
    condition     = aws_kms_key.compliance.enable_key_rotation == true
    error_message = "compliance KMS key must have automatic key rotation enabled"
  }

  # STRUCTURAL: find the CloudTrail encrypt statement by Sid; require Allow +
  # the aws:SourceAccount StringEquals bound to this account. Removing the
  # condition (or widening the account) fails this exactly.
  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.compliance.policy).Statement :
      s if s.Sid == "AllowCloudTrailEncrypt"
      && s.Effect == "Allow"
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "KMS 'AllowCloudTrailEncrypt' must be Allow and confined to aws:SourceAccount == this account (confused-deputy guard)"
  }
}

# -----------------------------------------------------------------------------
# INVARIANT 4: AWS Config records every supported resource type, incl. global
# -----------------------------------------------------------------------------
run "config_records_all_supported_resources" {
  command = plan

  assert {
    condition     = aws_config_configuration_recorder.this[0].recording_group[0].all_supported == true
    error_message = "Config recorder must record ALL supported resource types; disabling it blinds config-drift detection"
  }

  assert {
    condition     = aws_config_configuration_recorder.this[0].recording_group[0].include_global_resource_types == true
    error_message = "Config recorder must include global resource types (IAM, etc.), else global config drift is unrecorded"
  }
}
