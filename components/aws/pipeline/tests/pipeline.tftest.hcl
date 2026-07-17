# Unit tests for pipeline — the per-tenant ingestion substrate. The security
# contract under test: the connector's MSK IAM-auth grant is scoped to THIS
# tenant's own serverless cluster (cluster/topic/group ARNs under the tenant's
# cluster name), never Resource=["*"]. Cross-tenant broker/topic access is the
# regression this bites. When MSK is disabled for a tenant, the kafka-cluster
# grant is omitted entirely.
#
# Runs at command = plan against a mocked AWS provider. The connector inline
# policy is jsonencode()'d inside the workload-identity child module and surfaced
# through tenant_outputs[<id>].connector_policy_json, so it renders for real at
# plan time. aws_caller_identity is mocked so the account-qualified kafka ARNs
# resolve; the s3-bucket modules' data.aws_iam_policy_document gets a valid empty
# JSON stub to unblock the plan.

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
  # aws_batch_job_queue consumes the compute-environment .arn, ARN-validated at
  # plan — pin a valid one so the plan proceeds (irrelevant to the kafka scoping).
  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-west-2:123456789012:compute-environment/mock"
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

# MSK enabled (default): the connector's kafka-cluster grant is scoped to this
# tenant's own cluster/topic/group ARNs, never "*".
run "connector_kafka_scoped_to_tenant_cluster" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].connector_policy_json).Statement :
      contains(s.Action, "kafka-cluster:Connect")
      && can(tolist(s.Resource))
      && contains(tolist(s.Resource), "arn:aws:kafka:us-west-2:123456789012:cluster/development-pipeline-t1/*")
      && contains(tolist(s.Resource), "arn:aws:kafka:us-west-2:123456789012:topic/development-pipeline-t1/*")
      && contains(tolist(s.Resource), "arn:aws:kafka:us-west-2:123456789012:group/development-pipeline-t1/*")
      && !contains(tolist(s.Resource), "*")
    ])
    error_message = "connector kafka-cluster grant must scope Resource to the tenant's own cluster/topic/group ARNs, never \"*\""
  }
}

# MSK disabled: the kafka-cluster grant is omitted entirely — the connector keeps
# no MSK access at all.
run "connector_kafka_omitted_when_msk_disabled" {
  command = plan

  variables {
    tenants = {
      t1 = { msk_enabled = false }
    }
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.tenant_outputs["t1"].connector_policy_json).Statement :
      !contains(try(s.Action, []), "kafka-cluster:Connect")
    ])
    error_message = "with MSK disabled the connector must carry no kafka-cluster grant"
  }
}

# no-doubled-env guard at the caller boundary: a tenant keyed with the environment
# token would compose into a doubled "development-pipeline-development-..." name. The
# var.tenants validation must reject it. (The passing runs above, keyed "t1", are the
# positive direction — a short non-env key is accepted. The bucket-length-budget
# overflow direction is exercised in the governance suite, the repo's tightest
# tenant namespace.)
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
      "development-ingest" = {}
    }
  }

  expect_failures = [var.tenants]
}
