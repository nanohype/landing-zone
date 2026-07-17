# Unit tests for gateway — the per-tenant API Gateway substrate. The security
# contract under test: the cognito and WAF grants use the omit-the-statement
# pattern when the feature is disabled — NOT a Resource=["*"] fallback. The
# regression this bites: a tenant with cognito or WAF turned off silently receiving
# account-wide access to every Cognito user pool / WAFv2 web ACL. When the feature
# is ON, the grant is scoped to that tenant's own pool / web ACL ARN.
#
# Runs at command = plan against a mocked AWS provider. The gateway-admin / auth
# inline policies are jsonencode()'d inside the workload-identity child module and
# surfaced through tenant_outputs[<id>].{gateway_admin,gateway_auth}_policy_json.
# The cognito pool + web ACL ARNs are pinned via mock_resource so the enabled-scope
# assertions can match the exact ARN.

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
  mock_resource "aws_cognito_user_pool" {
    defaults = {
      arn = "arn:aws:cognito-idp:us-west-2:123456789012:userpool/us-west-2_TEST"
    }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:us-west-2:123456789012:regional/webacl/test/abc"
    }
  }
  # The API Gateway stage's access_log_settings.destination_arn is the log group
  # .arn, ARN-validated at plan — pin a valid one so the plan proceeds.
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-west-2:123456789012:log-group:/mock"
    }
  }
  # The WAF association's resource_arn is the stage .arn, ARN-validated at plan.
  mock_resource "aws_api_gateway_stage" {
    defaults = {
      arn = "arn:aws:apigateway:us-west-2::/restapis/abc123/stages/v1"
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
  tenants = {
    t1 = {}
  }
}

# Cognito + WAF enabled (default): the admin role's cognito grant is scoped to the
# tenant's own user pool ARN and the wafv2 grant to its web ACL ARN — never "*".
run "grants_scoped_to_tenant_resources_when_enabled" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].gateway_admin_policy_json).Statement :
      contains(try(s.Action, []), "cognito-idp:AdminCreateUser")
      && contains(tolist(s.Resource), "arn:aws:cognito-idp:us-west-2:123456789012:userpool/us-west-2_TEST")
      && !contains(tolist(s.Resource), "*")
    ])
    error_message = "gateway-admin cognito grant must scope Resource to the tenant's user pool ARN, never \"*\""
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].gateway_admin_policy_json).Statement :
      contains(try(s.Action, []), "wafv2:UpdateWebACL")
      && contains(tolist(s.Resource), "arn:aws:wafv2:us-west-2:123456789012:regional/webacl/test/abc")
      && !contains(tolist(s.Resource), "*")
    ])
    error_message = "gateway-admin wafv2 grant must scope Resource to the tenant's web ACL ARN, never \"*\""
  }
}

# Cognito + WAF disabled: the grants are OMITTED ENTIRELY — no cognito/waf action
# appears in either role's policy, and there is no Resource=["*"] fallback.
run "grants_omitted_when_disabled" {
  command = plan

  variables {
    tenants = {
      t1 = {
        cognito_enabled = false
        waf_enabled     = false
      }
    }
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.tenant_outputs["t1"].gateway_admin_policy_json).Statement :
      !contains(try(s.Action, []), "cognito-idp:AdminCreateUser")
    ])
    error_message = "with cognito disabled the gateway-admin role must carry no cognito grant (omit, not Resource=[\"*\"])"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.tenant_outputs["t1"].gateway_admin_policy_json).Statement :
      !contains(try(s.Action, []), "wafv2:UpdateWebACL")
    ])
    error_message = "with waf disabled the gateway-admin role must carry no wafv2 grant (omit, not Resource=[\"*\"])"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.tenant_outputs["t1"].gateway_auth_policy_json).Statement :
      !contains(try(s.Action, []), "cognito-idp:GetUser")
    ])
    error_message = "with cognito disabled the gateway-auth role must carry no cognito grant"
  }
}

# no-doubled-env guard at the caller boundary: a tenant keyed with the environment
# token would compose into a doubled "development-gateway-development-..." name. The
# var.tenants validation must reject it. (The passing runs above, keyed "t1", are the
# positive direction — a short non-env key is accepted.)
run "rejects_tenant_key_equal_to_environment" {
  command = plan

  variables {
    tenants = {
      development = {}
    }
  }

  expect_failures = [var.tenants]
}

# A tenant key prefixed with "<env>-" is the same defect.
run "rejects_tenant_key_prefixed_with_environment" {
  command = plan

  variables {
    tenants = {
      "development-api" = {}
    }
  }

  expect_failures = [var.tenants]
}
