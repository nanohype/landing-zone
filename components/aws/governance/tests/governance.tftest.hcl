# Unit tests for governance's caller-boundary naming guards. governance is the
# tightest tenant namespace in the repo — its account-qualified guardrails bucket
# (<env>-governance-<tenant>-<account:12>-guardrails) leaves the least headroom —
# so it is where the no-doubled-env and bucket-length-budget validations are
# exercised. Runs at command = plan against a mocked provider (no AWS access): a
# variable validation fires during variable evaluation, before any provider call.

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
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
  # The tenant-module run below plans the whole ledger. The mock's random default
  # is not an ARN, and the event archive validates its source's ARN at plan.
  mock_resource "aws_cloudwatch_event_bus" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:event-bus/mock"
    }
  }
  # The s3-bucket module validates the JSON of the policy documents it merges;
  # the mock's placeholder is not JSON. No assertion here reads a bucket policy.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  environment   = "development"
  region        = "us-east-1"
  vpc_id        = "vpc-0123456789abcdef0"
  cluster_sg_id = "sg-0123456789abcdef0"
  cluster_name  = "development-platform"
  team          = "platform"
}

# The guards are pure string checks on var.tenants keys, evaluated during
# variable evaluation before any resource is planned — so each negative case
# fails fast at the validation. The positive direction (a short, non-env key is
# accepted) is covered by the pipeline suite, whose passing runs are keyed "t1"
# against the identical guard.

# no-doubled-env: a tenant keyed with the environment token composes into a
# doubled "development-governance-development-..." name. The var.tenants
# validation must reject it.
run "rejects_tenant_key_equal_to_environment" {
  command = plan

  variables {
    tenants = {
      development = {}
    }
  }

  expect_failures = [var.tenants]
}

# no-doubled-env: a tenant key prefixed with "<env>-" is the same defect.
run "rejects_tenant_key_prefixed_with_environment" {
  command = plan

  variables {
    tenants = {
      "development-audit" = {}
    }
  }

  expect_failures = [var.tenants]
}

# bucket-global-uniqueness budget: at environment "development" (11 chars) the
# guardrails bucket leaves 16 chars for the tenant key (63 - 11 - 36). A 17-char
# key passes the RFC-1123 charset regex (<= 24) but overflows the 63-char S3
# name, so only the component-level length validation can catch it.
run "rejects_tenant_key_that_overflows_bucket_budget" {
  command = plan

  variables {
    tenants = {
      aaaaaaaaaaaaaaaaa = {} # 17 chars
    }
  }

  expect_failures = [var.tenants]
}

# ── the per-tenant audit ledger ──────────────────────────────────────────────
#
# The audit bucket, the audit and cost tables and the audit-writer role are the
# record a tenant's model use is reconstructed from, so what may write to them,
# and what protects them, is the contract. These runs test the tenant module
# directly, which is where those resources live.
#
# The writer's grant is compared as a whole action set: a Delete*, Update* or
# Get* verb, or any other addition, fails it. The set holds
# dynamodb:BatchWriteItem, which carries DeleteRequest as well as PutRequest, so
# the IAM layer alone does not make the tables append-only. This run pins the
# grant as it is; narrowing it belongs to the tenant-isolation work (lzg-2).
run "audit_ledger_is_written_by_a_narrow_role_and_protected_outside_development" {
  command = plan

  module {
    source = "./modules/tenant"
  }

  variables {
    environment           = "staging"
    region                = "us-east-1"
    account_id            = "123456789012"
    tenant_id             = "acme"
    cluster_name          = "staging-platform"
    force_destroy_buckets = false
    tenant_config         = {}
    tags                  = {}
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(module.audit_writer_irsa.role_policy_json).Statement : s.Action
      ])) == toset([
      "s3:PutObject",
      "kms:GenerateDataKey", "kms:Encrypt",
      "dynamodb:PutItem", "dynamodb:BatchWriteItem",
      "cloudwatch:PutMetricData", "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
      "events:PutEvents",
    ])
    error_message = "the audit writer's grant must be exactly the write verbs it needs: no delete, update or read on the ledger"
  }

  # Each ledger grant names only its own ledger resource.
  assert {
    condition = alltrue([
      for s in jsondecode(module.audit_writer_irsa.role_policy_json).Statement : (
        contains(s.Action, "s3:PutObject") ? s.Resource == ["${module.audit_bucket.s3_bucket_arn}/*"] :
        contains(s.Action, "kms:Encrypt") ? s.Resource == [aws_kms_key.audit.arn] :
        contains(s.Action, "dynamodb:PutItem") ? s.Resource == [aws_dynamodb_table.audit.arn, aws_dynamodb_table.cost.arn] :
        true
      )
    ])
    error_message = "the audit writer may put objects only in the audit bucket, encrypt only with the audit key, and write only the audit and cost tables"
  }

  assert {
    condition     = aws_dynamodb_table.audit.deletion_protection_enabled == true && aws_dynamodb_table.cost.deletion_protection_enabled == true
    error_message = "outside development, with no teardown lever, the audit and cost tables must refuse deletion"
  }

  assert {
    condition     = aws_dynamodb_table.audit.point_in_time_recovery[0].enabled == true && aws_dynamodb_table.cost.point_in_time_recovery[0].enabled == true
    error_message = "the audit and cost tables must keep point-in-time recovery by default"
  }

  assert {
    condition     = aws_kms_key.audit.enable_key_rotation == true && aws_kms_key.audit.deletion_window_in_days == 30
    error_message = "the audit key must rotate and keep the 30-day deletion window"
  }
}
