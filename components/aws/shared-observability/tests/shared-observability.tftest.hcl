# Unit tests for shared-observability — the fleet-wide alarm destination. The contracts under
# test: three severity topics exist, they are SSE-KMS with the alert CMK, and both the topic
# policies and the CMK policy admit cross-account CloudWatch publishing scoped by
# aws:SourceOrgID — the org-membership grant that lets the fleet grow without an edit here, and
# the exact grant that otherwise breaks alarm delivery silently.
#
# aws:SourceOrgID (not aws:PrincipalOrgID) is the load-bearing choice: a service principal
# acting cross-account carries SourceOrgID, not PrincipalOrgID.
#
# Runs at command = plan against a mocked provider; every policy is jsonencode()'d from static
# inputs, so it renders for real at plan time.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "777777777777"
      arn        = "arn:aws:iam::777777777777:user/test"
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
      arn = "arn:aws:kms:us-west-2:777777777777:key/mock"
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-west-2:777777777777:mock"
    }
  }
}

variables {
  environment     = "shared"
  region          = "us-west-2"
  team            = "sre"
  organization_id = "o-abcdef1234"
}

# Three severity topics, each SSE-KMS with the alert CMK.
run "three_topics_encrypted_with_alert_cmk" {
  command = plan

  assert {
    condition     = length(aws_sns_topic.this) == 3
    error_message = "shared-observability must create three severity topics (critical/warning/info)"
  }

  assert {
    condition = alltrue([
      for t in aws_sns_topic.this : t.kms_master_key_id == aws_kms_key.alerts.arn
    ])
    error_message = "every central topic must be SSE-KMS with the alert CMK, or a cross-account alarm publish is dropped"
  }
}

# Each topic policy admits CloudWatch publishing scoped by aws:SourceOrgID — the org-membership
# grant. Not aws:SourceAccount (which would pin it to the shared-services account and drop every
# workload account's alarms), and not a bare wildcard.
run "topic_policies_are_org_scoped" {
  command = plan

  assert {
    condition = alltrue([
      for sev, pol in aws_sns_topic_policy.this : anytrue([
        for s in jsondecode(pol.policy).Statement :
        try(s.Principal.Service, "") == "cloudwatch.amazonaws.com"
        && contains(try(tolist(s.Action), [s.Action]), "SNS:Publish")
        && try(s.Condition.StringEquals["aws:SourceOrgID"], "") == "o-abcdef1234"
      ])
    ])
    error_message = "every central topic policy must admit cloudwatch.amazonaws.com SNS:Publish scoped by aws:SourceOrgID"
  }
}

# The alert CMK policy grants org CloudWatch the encrypt actions, scoped by aws:SourceOrgID.
run "alert_key_policy_is_org_scoped" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.alerts.policy).Statement :
      s if try(s.Principal.Service, "") == "cloudwatch.amazonaws.com"
      && contains(try(tolist(s.Action), [s.Action]), "kms:GenerateDataKey*")
      && try(s.Condition.StringEquals["aws:SourceOrgID"], "") == "o-abcdef1234"
    ]) == 1
    error_message = "the alert CMK must grant org CloudWatch kms:GenerateDataKey* scoped by aws:SourceOrgID"
  }
}

# A malformed organization id is rejected at the boundary — an unscoped or typo'd org id would
# void the cross-account publish grant.
run "rejects_malformed_organization_id" {
  command = plan

  variables {
    organization_id = "not-an-org-id"
  }

  expect_failures = [var.organization_id]
}
