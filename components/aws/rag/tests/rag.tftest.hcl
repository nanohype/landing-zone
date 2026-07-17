# Unit tests for rag — the per-tenant RAG substrate. The security contract under
# test: each tenant's bedrock-api role scopes Bedrock model invocation to the
# tenant's model allowlist (foundation-model + cross-region inference-profile
# ARNs), never Resource="*".
#
# Runs at command = plan against a mocked AWS provider (no account, no network).
# aws_caller_identity / aws_partition are mocked so the account- and
# partition-qualified ARNs resolve; the bedrock-api inline policy is built with
# jsonencode() from vars + locals, so its content is real and known at plan time.
# The policy is surfaced through the tenant + root outputs
# (tenants[<id>].bedrock_api_policy_json) since it renders inside a child module.

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
  # aws_eks_pod_identity_association validates role_arn as a real ARN at plan; the
  # mock's random default isn't parseable, so pin every mocked role to a valid ARN.
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
  cluster_name  = "development-hub"
  team          = "platform"
  tenants = {
    t1 = {}
  }
}

# Default allowlist: Bedrock invoke is scoped to the tenant's model families. The
# anthropic.* foundation-model AND its inference-profile ARN are both present (both
# are required to invoke via a cross-region profile), and the "*" wildcard is
# absent. can(tolist(...)) also fails the assertion if Resource regresses to the
# bare "*" string.
run "bedrock_api_default_allowlist_is_model_scoped" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenants["t1"].bedrock_api_policy_json).Statement :
      contains(s.Action, "bedrock:InvokeModel")
      && can(tolist(s.Resource))
      && contains(tolist(s.Resource), "arn:aws:bedrock:*::foundation-model/anthropic.*")
      && contains(tolist(s.Resource), "arn:aws:bedrock:*:123456789012:inference-profile/*anthropic.*")
      && !contains(tolist(s.Resource), "*")
    ])
    error_message = "bedrock-api InvokeModel must scope Resource to the allowlist's foundation-model + inference-profile ARNs, never \"*\""
  }

  # The embedding families a RAG tenant retrieves with are covered by default too.
  assert {
    condition = anytrue([
      for s in jsondecode(output.tenants["t1"].bedrock_api_policy_json).Statement :
      contains(s.Action, "bedrock:InvokeModel")
      && contains(tolist(s.Resource), "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-*")
      && contains(tolist(s.Resource), "arn:aws:bedrock:*::foundation-model/cohere.embed-*")
    ])
    error_message = "default rag allowlist must cover the Titan + Cohere embedding families"
  }
}

# The scoping is variable-driven: an empty allowlist is the explicit escape hatch
# back to Resource=["*"]. Proving both directions rules out a hardcoded default.
run "bedrock_api_empty_allowlist_is_wildcard" {
  command = plan

  variables {
    tenants = {
      t1 = {
        bedrock_allowed_model_ids = []
      }
    }
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenants["t1"].bedrock_api_policy_json).Statement :
      contains(s.Action, "bedrock:InvokeModel")
      && can(tolist(s.Resource)) && length(tolist(s.Resource)) == 1 && contains(tolist(s.Resource), "*")
    ])
    error_message = "an empty tenant allowlist must fall back to Resource=[\"*\"] (the explicit escape hatch)"
  }
}

# no-doubled-env guard at the caller boundary: a tenant keyed with the
# environment token would compose into a doubled "development-rag-development-..."
# name. The var.tenants validation must reject it. (The passing runs above,
# keyed "t1", are the positive direction — a short non-env key is accepted.)
run "rejects_tenant_key_equal_to_environment" {
  command = plan

  variables {
    tenants = {
      development = {}
    }
  }

  expect_failures = [var.tenants]
}
