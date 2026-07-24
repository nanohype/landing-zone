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
  environment = "development"
  region      = "us-west-2"
  network = {
    vpc_id             = "vpc-0123456789abcdef0"
    ownership_mode     = "create"
    private_subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    private_subnet_azs = ["us-west-2a", "us-west-2b"]
  }
  cluster_sg_id = "sg-0123456789abcdef0"
  cluster_name  = "development-platform"
  team          = "platform"
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

# no-doubled-env guard at the caller boundary: a tenant keyed with the environment
# token would compose into a doubled "development-druid-development-..." name. The
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

# --- adopt-mode network preflight -------------------------------------------
# In adopt mode druid participates in a VPC it does not own. network-preflight.tf reads each
# private subnet and the cluster SG and asserts they reside in network.vpc_id. The overrides
# stand in for the AWS reads (data sources are gated on adopt mode, so create-mode runs above
# never execute them and need no mocks).

# Happy adopt path: every subnet and the cluster SG are in the adopted VPC, so the plan
# proceeds and the tenant substrate still renders. An un-indexed override_data target applies
# its values to every instance of the for_each/count data source.
run "adopt_mode_plans_with_matching_placement" {
  command = plan

  variables {
    network = {
      vpc_id             = "vpc-adopt00000000000"
      ownership_mode     = "adopt"
      private_subnet_ids = ["subnet-adopt0000000a", "subnet-adopt0000000b"]
      private_subnet_azs = ["us-west-2a", "us-west-2b"]
    }
  }

  override_data {
    target = data.aws_subnet.placement
    values = { vpc_id = "vpc-adopt00000000000" }
  }
  override_data {
    target = data.aws_security_group.cluster
    values = { vpc_id = "vpc-adopt00000000000" }
  }

  assert {
    condition     = output.tenant_outputs["t1"].ingestion_policy_json != null
    error_message = "adopt-mode plan with matching placement must render the tenant substrate"
  }
}

# A private subnet from a different VPC must fail at plan, naming the subnet — the acceptance
# criterion for this plan. Every adopted subnet resolves to a foreign VPC; the cluster SG is
# in the adopted VPC so the only expected failure is the subnet placement postcondition.
run "adopt_mode_rejects_foreign_subnet" {
  command = plan

  variables {
    network = {
      vpc_id             = "vpc-adopt00000000000"
      ownership_mode     = "adopt"
      private_subnet_ids = ["subnet-foreign00000a", "subnet-foreign00000b"]
      private_subnet_azs = ["us-west-2a", "us-west-2b"]
    }
  }

  override_data {
    target = data.aws_subnet.placement
    values = { vpc_id = "vpc-somewhere-else00" }
  }
  override_data {
    target = data.aws_security_group.cluster
    values = { vpc_id = "vpc-adopt00000000000" }
  }

  expect_failures = [data.aws_subnet.placement]
}

# A cluster security group from a different VPC must also fail at plan — a bare-id membership
# reference to an SG in another VPC would attach an ingress rule that silently never matches.
run "adopt_mode_rejects_foreign_cluster_sg" {
  command = plan

  variables {
    network = {
      vpc_id             = "vpc-adopt00000000000"
      ownership_mode     = "adopt"
      private_subnet_ids = ["subnet-adopt0000000a", "subnet-adopt0000000b"]
      private_subnet_azs = ["us-west-2a", "us-west-2b"]
    }
  }

  override_data {
    target = data.aws_subnet.placement
    values = { vpc_id = "vpc-adopt00000000000" }
  }
  override_data {
    target = data.aws_security_group.cluster
    values = { vpc_id = "vpc-somewhere-else00" }
  }

  expect_failures = [data.aws_security_group.cluster]
}

# AZ coverage is druid's own floor, checked in both modes: fewer than two distinct zones
# fails before Aurora's DB subnet group would reject it at apply.
run "rejects_single_az_coverage" {
  command = plan

  variables {
    network = {
      vpc_id             = "vpc-0123456789abcdef0"
      ownership_mode     = "create"
      private_subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
      private_subnet_azs = ["us-west-2a", "us-west-2a"]
    }
  }

  expect_failures = [terraform_data.az_coverage]
}
