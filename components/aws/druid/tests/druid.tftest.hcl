# Unit tests for druid — the per-tenant Druid substrate. The security contract
# under test: the ingestion and MSK-client roles' kafka-cluster IAM-auth grants
# are scoped to THIS tenant's own serverless cluster (cluster/topic/group ARNs
# under "<env>-druid-<id>-msk"), never Resource=["*"]. Cross-tenant broker access
# is the regression this bites. With MSK disabled, ingestion carries no
# kafka-cluster grant and the MSK-client role is not created.
#
# Runs at command = plan against a mocked AWS provider. The inline policies are
# jsonencode()'d inside the workload-identity child module and surfaced through
# tenant_outputs[<id>].{ingestion,msk_client}_policy_json.

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

# MSK enabled (default): ingestion + MSK-client kafka grants are scoped to the
# tenant's own cluster/topic/group ARNs, never "*".
run "kafka_grants_scoped_to_tenant_cluster" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].ingestion_policy_json).Statement :
      contains(s.Action, "kafka-cluster:Connect")
      && can(tolist(s.Resource))
      && contains(tolist(s.Resource), "arn:aws:kafka:us-west-2:123456789012:cluster/development-druid-t1-msk/*")
      && contains(tolist(s.Resource), "arn:aws:kafka:us-west-2:123456789012:topic/development-druid-t1-msk/*")
      && !contains(tolist(s.Resource), "*")
    ])
    error_message = "druid ingestion kafka-cluster grant must scope Resource to the tenant's own MSK cluster ARNs, never \"*\""
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.tenant_outputs["t1"].msk_client_policy_json).Statement :
      contains(s.Action, "kafka-cluster:CreateTopic")
      && contains(tolist(s.Resource), "arn:aws:kafka:us-west-2:123456789012:topic/development-druid-t1-msk/*")
      && !contains(tolist(s.Resource), "*")
    ])
    error_message = "druid msk-client kafka-cluster grant must scope Resource to the tenant's own MSK cluster ARNs, never \"*\""
  }
}

# MSK disabled: ingestion has no kafka-cluster grant and the MSK-client role's
# policy output is null (the role is not created).
run "kafka_omitted_when_msk_disabled" {
  command = plan

  variables {
    tenants = {
      t1 = { msk_enabled = false }
    }
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.tenant_outputs["t1"].ingestion_policy_json).Statement :
      !contains(try(s.Action, []), "kafka-cluster:Connect")
    ])
    error_message = "with MSK disabled the ingestion role must carry no kafka-cluster grant"
  }

  assert {
    condition     = output.tenant_outputs["t1"].msk_client_policy_json == null
    error_message = "with MSK disabled the msk-client role must not be created (policy output null)"
  }
}
