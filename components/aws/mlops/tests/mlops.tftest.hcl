# Unit tests for mlops — the per-tenant ML lifecycle substrate. The security
# contract under test: each tenant's three IRSA roles (training-worker,
# model-registry, mlops-api) reach only THIS tenant's own resources — the datasets
# and artifacts buckets, the MLOps KMS key, the experiments and model-registry
# tables, and the training queue — never Resource=["*"]. The only wildcards the
# roles carry are the API-level actions that do not support resource-level
# permissions (cloudwatch/logs writes). A regression that widens the storage/KMS/DDB
# grants to "*" is what this bites, plus the ECR grant appearing only when the tenant
# opts into an in-tenant registry.
#
# Runs at command = plan against a mocked AWS provider. The IRSA inline policies are
# jsonencode()'d inside the workload-identity child module and surfaced through
# tenants[<id>].{training_worker,model_registry,mlops_api}_policy_json, so their
# content renders for real at plan time. The bucket modules' data.aws_iam_policy_document
# is handed a valid empty JSON stub to unblock the plan.

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

# Every storage/KMS/DDB/queue grant across the three roles is resource-scoped —
# never Resource=["*"]. Regressing any of them to the bare wildcard fails here.
run "grants_are_resource_scoped_not_wildcard" {
  command = plan

  # training-worker: bucket rw scoped, KMS scoped, experiments-table scoped.
  assert {
    condition = anytrue([
      for s in jsondecode(output.tenants["t1"].training_worker_policy_json).Statement :
      contains(try(s.Action, []), "s3:PutObject")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "training-worker s3 grant must be scoped to the datasets/artifacts bucket ARNs, never Resource=[\"*\"]"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenants["t1"].training_worker_policy_json).Statement :
      contains(try(s.Action, []), "kms:GenerateDataKey")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "training-worker kms grant must be scoped to the tenant KMS key ARN, never Resource=[\"*\"]"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenants["t1"].training_worker_policy_json).Statement :
      contains(try(s.Action, []), "dynamodb:PutItem")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "training-worker dynamodb grant must be scoped to the experiments table ARN, never Resource=[\"*\"]"
  }

  # model-registry: registry-table write scoped, never "*".
  assert {
    condition = anytrue([
      for s in jsondecode(output.tenants["t1"].model_registry_policy_json).Statement :
      contains(try(s.Action, []), "dynamodb:PutItem")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "model-registry dynamodb grant must be scoped to the model-registry table ARN, never Resource=[\"*\"]"
  }

  # mlops-api: training-queue send scoped, never "*".
  assert {
    condition = anytrue([
      for s in jsondecode(output.tenants["t1"].mlops_api_policy_json).Statement :
      contains(try(s.Action, []), "sqs:SendMessage")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "mlops-api sqs grant must be scoped to the training queue ARN, never Resource=[\"*\"]"
  }
}

# The ECR grant is opt-in (ecr_enabled, default true): present and scoped by default
# on the roles that pull/describe images, and OMITTED entirely when the tenant turns
# the in-tenant registry off — proving the grant is toggle-driven, not always-on.
run "ecr_grant_present_by_default" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenants["t1"].training_worker_policy_json).Statement :
      contains(try(s.Action, []), "ecr:BatchGetImage")
      && can(tolist(s.Resource)) && !contains(tolist(s.Resource), "*")
    ])
    error_message = "with ecr_enabled (default) the training-worker must carry an ecr pull grant scoped to the tenant repository ARN, never \"*\""
  }
}

run "ecr_grant_omitted_when_disabled" {
  command = plan

  variables {
    tenants = {
      t1 = { ecr_enabled = false }
    }
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.tenants["t1"].training_worker_policy_json).Statement :
      !contains(try(s.Action, []), "ecr:BatchGetImage")
    ])
    error_message = "with ecr_enabled=false the training-worker must carry no ecr grant"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.tenants["t1"].mlops_api_policy_json).Statement :
      !contains(try(s.Action, []), "ecr:DescribeImages")
    ])
    error_message = "with ecr_enabled=false the mlops-api must carry no ecr grant"
  }
}

# no-doubled-env guard at the caller boundary: a tenant keyed with the environment
# token would compose into a doubled "development-mlops-development-..." name. The
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
      "development-lab" = {}
    }
  }

  expect_failures = [var.tenants]
}
