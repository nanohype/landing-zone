# Cost categories, asserted on the one field Cost Explorer validates by enumeration.
#
# CreateCostCategoryDefinition accepts a single rule version, CostCategoryExpression.v1.
# Any other value is rejected at apply, after every resource planned before it has been
# created, so the component must refuse it at plan instead.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDTEST"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_ce_anomaly_monitor" {
    defaults = {
      arn = "arn:aws:ce::123456789012:anomalymonitor/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  environment         = "org"
  region              = "us-east-1"
  team                = "platform"
  tags                = {}
  org_budget_limit    = 10000
  budget_alert_emails = ["cost-alerts@example.com"]
  enable_cur_export   = false
}

# A category that does not name a rule version gets the one Cost Explorer accepts.
run "an_omitted_rule_version_defaults_to_the_accepted_one" {
  command = plan

  variables {
    cost_categories = {
      ByEnvironment = {
        rules = [
          { value = "Production", rule = { tags = { key = "Environment", values = ["production"] } } },
        ]
      }
    }
  }

  assert {
    condition     = aws_ce_cost_category.this["ByEnvironment"].rule_version == "CostCategoryExpression.v1"
    error_message = "an omitted rule_version must render as CostCategoryExpression.v1, the only value CreateCostCategoryDefinition accepts"
  }
}

# The value the management leaf used to carry. It plans cleanly without the validation and
# fails CreateCostCategoryDefinition on apply.
run "a_rule_version_cost_explorer_rejects_fails_the_plan" {
  command = plan

  variables {
    cost_categories = {
      ByEnvironment = {
        rule_version = "1"
        rules = [
          { value = "Production", rule = { tags = { key = "Environment", values = ["production"] } } },
        ]
      }
    }
  }

  expect_failures = [
    var.cost_categories,
  ]
}
