# Unit tests for llm — the per-tenant model-serving substrate. The security
# contract under test: each tenant's inference-server and api-gateway IRSA roles
# reach only THIS tenant's own resources — the model bucket, model KMS key, EFS
# cache, inference queue, and inference table — never Resource=["*"]. The only
# wildcards the roles carry are the API-level actions that do not support
# resource-level permissions (ecr:GetAuthorizationToken, cloudwatch/logs writes).
# A regression that widens the storage/queue grants to "*" is what this bites, plus
# the Hugging-Face token secret grant being present only when the tenant opts in.
#
# Runs at command = plan against a mocked AWS provider. The IRSA inline policies are
# jsonencode()'d inside the workload-identity child module and surfaced through
# tenant_outputs[<id>].{inference_server,api_gateway}_policy_json, so their content
# renders for real at plan time. The model-bucket module's data.aws_iam_policy_document
# is handed a valid empty JSON stub to unblock the plan; every asserted Resource is a
# concrete ARN the mock resolves, so an accidental widening to "*" fails the assertion.

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
}

variables {
  environment        = "development"
  region             = "us-west-2"
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  cluster_sg_id      = "sg-0123456789abcdef0"
  cluster_name       = "development-platform"
  team               = "platform"
  tenants = {
    t1 = {}
  }
}

# The storage/queue grants are resource-scoped: the inference-server's S3 and KMS
# grants and the api-gateway's SQS and DynamoDB grants each carry a concrete ARN
# list with no bare "*". Regressing any of them to Resource=["*"] fails here.
run "grants_are_resource_scoped_not_wildcard" {
  command = plan

  # inference-server: model-bucket read is scoped, never "*".
  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].inference_server_policy_json).Statement :
      contains(try(s.Action, []), "s3:GetObject")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "inference-server s3:GetObject must be scoped to the model bucket ARNs, never Resource=[\"*\"]"
  }

  # inference-server: model KMS decrypt is scoped to the tenant's key, never "*".
  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].inference_server_policy_json).Statement :
      contains(try(s.Action, []), "kms:Decrypt")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "inference-server kms:Decrypt must be scoped to the model KMS key ARN, never Resource=[\"*\"]"
  }

  # api-gateway: inference-queue send is scoped to the tenant's queue, never "*".
  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].api_gateway_policy_json).Statement :
      contains(try(s.Action, []), "sqs:SendMessage")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "api-gateway sqs:SendMessage must be scoped to the inference queue ARN, never Resource=[\"*\"]"
  }

  # api-gateway: inference-table access is scoped to the tenant's table, never "*".
  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].api_gateway_policy_json).Statement :
      contains(try(s.Action, []), "dynamodb:PutItem")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "api-gateway dynamodb grant must be scoped to the inference table ARN, never Resource=[\"*\"]"
  }
}

# The HF-token secret grant is opt-in (hf_token_enabled, default true): present and
# scoped by default, and OMITTED entirely when the tenant turns it off — proving the
# grant is toggle-driven, not always-on.
run "hf_token_secret_grant_present_by_default" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].inference_server_policy_json).Statement :
      contains(try(s.Action, []), "secretsmanager:GetSecretValue")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "with hf_token_enabled (default) the inference-server must carry a secretsmanager:GetSecretValue grant scoped to the HF token secret, never \"*\""
  }
}

run "hf_token_secret_grant_omitted_when_disabled" {
  command = plan

  variables {
    tenants = {
      t1 = { hf_token_enabled = false }
    }
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.tenant_outputs["t1"].inference_server_policy_json).Statement :
      !contains(try(s.Action, []), "secretsmanager:GetSecretValue")
    ])
    error_message = "with hf_token_enabled=false the inference-server must carry no secretsmanager grant"
  }
}

# no-doubled-env guard at the caller boundary: a tenant keyed with the environment
# token would compose into a doubled "development-llm-development-..." name. The
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
      "development-serving" = {}
    }
  }

  expect_failures = [var.tenants]
}
