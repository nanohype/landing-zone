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
}

variables {
  environment   = "development"
  region        = "us-west-2"
  vpc_id        = "vpc-0123456789abcdef0"
  cluster_sg_id = "sg-0123456789abcdef0"
  cluster_name  = "development-platform"
  team          = "platform"
}

# The guards are pure string checks on var.tenants keys, evaluated during
# variable evaluation before any resource is planned — so each negative case
# fails fast at the validation. The positive direction (a short, non-env key is
# accepted) is covered by the rag suite, whose passing runs are keyed "t1"
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
