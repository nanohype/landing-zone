# Unit tests for the AMG Athena data source — the wiring that lets the finance
# board read cost out of the ACCOUNT cost pipeline's Athena workgroup.
#
# The contract under test is that the grant appears when, and only when, the
# cost-pipeline SSM subtree publishes every value it needs, and that when it does
# appear it carries the three permissions whose absence produces a silent or
# opaque failure rather than a loud one:
#
#   * PutObject on the results bucket. Athena stages every result object in the
#     workgroup's output location before Grafana reads a row, so a read-only
#     grant dies at the write with an error naming the bucket, not the missing
#     permission.
#   * kms:GenerateDataKey on the pipeline's data key. Both buckets are SSE-KMS;
#     without it the query plans, runs, and fails at the same write.
#   * ATHENA in the workspace's data_sources. The IAM can be perfect and the
#     datasource still will not exist in Grafana.
#
# Runs at command = plan against a mocked provider. The policy is jsonencode()'d
# from values resolved at plan time, so it renders for real.

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
  # The mock's random default is not a parseable ARN, and the AMP/AMG resources
  # that consume a role ARN validate it. Pin one.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-managed-monitoring"
    }
  }
}

variables {
  cluster_name = "development-platform"
  environment  = "development"
  region       = "us-west-2"
  team         = "platform"
}

run "athena_grant_can_write_its_own_query_results" {
  command = plan

  # The published subtree, as cost-pipeline writes it.
  override_data {
    target = data.aws_ssm_parameters_by_path.cost_pipeline
    values = {
      names = [
        "/eks-agent-platform/org/cost-pipeline/athena_workgroup",
        "/eks-agent-platform/org/cost-pipeline/athena_database_arn",
        "/eks-agent-platform/org/cost-pipeline/athena_results_bucket_arn",
        "/eks-agent-platform/org/cost-pipeline/cur_bucket_arn",
        "/eks-agent-platform/org/cost-pipeline/data_kms_key_arn",
      ]
      values = [
        "org-123456789012-us-west-2-cost",
        "arn:aws:glue:us-west-2:123456789012:database/org_123456789012_us_west_2_cost",
        "arn:aws:s3:::org-123456789012-us-west-2-cost-athena-123456789012",
        "arn:aws:s3:::org-123456789012-cur-export",
        "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555",
      ]
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.grafana_workspace_athena) == 1
    error_message = "the cost subtree is fully published, so the Athena grant must exist"
  }

  # The write, not the read. This is the permission whose absence produces the
  # failure cost-access already documents.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.grafana_workspace_athena[0].policy).Statement :
      contains(s.Action, "s3:PutObject") &&
      contains(s.Resource, "arn:aws:s3:::org-123456789012-us-west-2-cost-athena-123456789012/*")
    ])
    error_message = "Athena stages results in the output bucket before any row is returned; without s3:PutObject on it every query fails at the write"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.grafana_workspace_athena[0].policy).Statement :
      contains(s.Action, "kms:GenerateDataKey") &&
      contains(s.Resource, "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555")
    ])
    error_message = "both buckets are SSE-KMS under the pipeline's data key; without GenerateDataKey the result write is denied"
  }

  # Scoped, not "*" — this grant reaches one workgroup, not every query in the
  # account.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.grafana_workspace_athena[0].policy).Statement :
      contains(s.Action, "athena:StartQueryExecution") &&
      contains(s.Resource, "arn:aws:athena:us-west-2:123456789012:workgroup/org-123456789012-us-west-2-cost")
    ])
    error_message = "query execution must be scoped to the account cost workgroup"
  }

  # The IAM can be perfect and the datasource still not exist.
  assert {
    condition     = contains(aws_grafana_workspace.this.data_sources, "ATHENA")
    error_message = "ATHENA must be in the workspace data_sources or Grafana has no datasource to attach the grant to"
  }
}

# The half that matters for every account today: nothing has applied the cost
# pipeline, so the subtree is empty and this component must still apply.
run "no_cost_pipeline_means_no_athena_wiring_and_a_clean_apply" {
  command = plan

  override_data {
    target = data.aws_ssm_parameters_by_path.cost_pipeline
    values = {
      names  = []
      values = []
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.grafana_workspace_athena) == 0
    error_message = "with no published cost subtree there is nothing to grant against; emitting a policy here would name empty ARNs that IAM accepts and then denies at query time"
  }

  assert {
    condition     = !contains(aws_grafana_workspace.this.data_sources, "ATHENA")
    error_message = "advertising an ATHENA datasource with no workgroup behind it is the dead-path shape this wiring exists to avoid"
  }

  # And the rest of the component is unaffected — this is the assertion that
  # would catch the by-path read being turned back into a by-name one, which
  # fails the whole plan when the parameter is absent.
  assert {
    condition     = contains(aws_grafana_workspace.this.data_sources, "PROMETHEUS")
    error_message = "an absent cost pipeline must not take the AMP datasource down with it"
  }
}
