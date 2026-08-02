# The account's CUR 2.0 export, asserted where its shape is decided.
#
# This export is the billed side of every cost question asked about this account, and
# the failure it can have is silent in both directions: a missing table configuration
# removes a column rather than erroring, and a published location that disagrees with
# the delivered one produces an empty table rather than a broken one. Both read as
# "this account spent nothing".

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
      region = "us-west-2"
    }
  }
  # The S3 bucket module builds its policy from a policy document. A generated
  # placeholder is not JSON, so the bucket-policy resource rejects it during plan and
  # the run dies before reaching a single assertion — the component would look untestable
  # when only the fixture is missing.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  # The anomaly subscription validates its monitor ARNs client-side, so a generated
  # placeholder fails the plan before any assertion runs.
  mock_resource "aws_ce_anomaly_monitor" {
    defaults = {
      arn = "arn:aws:ce::123456789012:anomalymonitor/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  environment      = "org"
  region           = "us-west-2"
  team             = "platform"
  tags             = {}
  org_budget_limit = 10000
  # Anomaly subscribers are built with a dynamic block over this list, and the resource
  # requires at least one, so an empty list makes the component unplannable for reasons
  # unrelated to what this suite asserts.
  budget_alert_emails = ["cost-alerts@example.com"]
  enable_cur_export   = true
}

# The reason this export exists in the shape it does.
#
# A Bedrock model invocation is not a taggable resource, so no `resourceTags/` column
# is ever populated on one. Attribution comes from the calling identity instead, and
# AWS gates that behind a single table configuration: without INCLUDE_IAM_PRINCIPAL_DATA
# there is no `line_item_iam_principal` column and no `iamPrincipal/<key>` tag columns.
#
# Dropping it does not fail an apply, does not fail a crawl, and does not fail a query.
# It removes a column, and every attribution query filtering on that column then returns
# no rows — successfully — which a budget reads as zero spend and a kill switch reads as
# nothing to do.
run "the_export_carries_caller_identity" {
  command = plan

  assert {
    condition = alltrue([
      for e in aws_bcmdataexports_export.cur[0].export :
      length(e.data_query) > 0 && alltrue([
        for q in e.data_query :
        try(q.table_configurations["COST_AND_USAGE_REPORT"]["INCLUDE_IAM_PRINCIPAL_DATA"], "") == "TRUE"
      ])
    ])
    error_message = "the CUR 2.0 export must set INCLUDE_IAM_PRINCIPAL_DATA — it is the only source of line_item_iam_principal and the iamPrincipal/* tag columns, and Amazon Bedrock spend can be attributed by nothing else, so without it every per-platform cost query returns zero rows and succeeds"
  }

  # Resource-level detail is what makes the export answerable at all — without it every
  # line collapses to a service total and no tag column has anything to hang off.
  assert {
    condition = alltrue([
      for e in aws_bcmdataexports_export.cur[0].export :
      alltrue([
        for q in e.data_query :
        try(q.table_configurations["COST_AND_USAGE_REPORT"]["INCLUDE_RESOURCES"], "") == "TRUE"
      ])
    ])
    error_message = "the export must include resource-level detail; without it there is nothing for a per-resource or per-identity attribution to read"
  }

  # Hourly, not monthly. A budget that enforces mid-month needs to see spend accrue
  # inside the month; at MONTHLY granularity the export answers "what did this account
  # spend in July" and cannot answer "what has this platform spent so far".
  assert {
    condition = alltrue([
      for e in aws_bcmdataexports_export.cur[0].export :
      alltrue([
        for q in e.data_query :
        try(q.table_configurations["COST_AND_USAGE_REPORT"]["TIME_GRANULARITY"], "") == "HOURLY"
      ])
    ])
    error_message = "the export must be HOURLY — a monthly-granularity export cannot answer month-to-date, which is the only question a budget asks"
  }
}

# The table configuration is complete, and it only gets one chance to be.
#
# Two AWS rules make this a hard gate rather than tidiness. "If a value is set for
# table_configurations, all configuration values must be set" — a partial map is
# rejected outright, and for the CUR report BILLING_VIEW_ARN is required on top of the
# documented settings. And "table configurations can't be changed after an export is
# created": a wrong or missing key is not a diff to correct on the next apply, it is a
# destroy and recreate, and AWS states existing exports never retroactively gain
# identity data.
run "the_table_configuration_is_complete" {
  command = plan

  assert {
    condition = alltrue([
      for e in aws_bcmdataexports_export.cur[0].export :
      alltrue([
        for q in e.data_query :
        length(setsubtract(
          toset([
            "BILLING_VIEW_ARN",
            "TIME_GRANULARITY",
            "INCLUDE_RESOURCES",
            "INCLUDE_SPLIT_COST_ALLOCATION_DATA",
            "INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY",
            "INCLUDE_IAM_PRINCIPAL_DATA",
          ]),
          toset(keys(try(q.table_configurations["COST_AND_USAGE_REPORT"], {})))
        )) == 0
      ])
    ])
    error_message = "every COST_AND_USAGE_REPORT table configuration key must be set — AWS rejects a partial map, and the map is immutable after creation, so a key missed here costs a destroy and recreate rather than an edit"
  }

  assert {
    condition = alltrue([
      for e in aws_bcmdataexports_export.cur[0].export :
      alltrue([
        for q in e.data_query :
        endswith(try(q.table_configurations["COST_AND_USAGE_REPORT"]["BILLING_VIEW_ARN"], ""), ":billingview/primary")
      ])
    ])
    error_message = "the export must read the account's primary billing view — a different view is a different set of costs, and the budget would enforce against numbers that are not the bill"
  }
}

# The delivery grant is scoped to a caller, not just to an account.
#
# SourceAccount alone answers "did something in this account ask?", which is true of
# every export in the account — including one owned by a different estate sharing it.
# AWS publishes the SourceArn condition as part of the required policy, and dropping it
# changes nothing observable: delivery still works, the export stays HEALTHY, and the
# bucket is simply reachable by a broader set of callers than intended.
run "the_delivery_grant_names_the_caller_it_trusts" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(local.cur_bucket_policy).Statement :
      try(s.Condition.ArnLike["aws:SourceArn"], "") != "" &&
      try(s.Condition.StringEquals["aws:SourceAccount"], "") != ""
    ])
    error_message = "the CUR bucket's delivery statement must carry BOTH aws:SourceAccount and an aws:SourceArn ArnLike — SourceAccount alone admits any export in the account, and nothing about the looser grant is visible in a plan, an apply, or the export's health"
  }

  # Objects only. The service writes and does nothing else, so a grant on the bucket ARN
  # itself, or a read of the bucket policy, is reach the delivery path never uses.
  assert {
    condition = alltrue([
      for s in jsondecode(local.cur_bucket_policy).Statement :
      length(s.Action) == 1 && contains(s.Action, "s3:PutObject") &&
      length(s.Resource) > 0 && alltrue([for r in s.Resource : endswith(r, "/*")])
    ])
    error_message = "the delivery grant must be s3:PutObject on the key space only — the bucket ARN and s3:GetBucketPolicy are reach Data Exports does not use"
  }
}

# The published location and the delivered location are the same location.
#
# Consumers build an Athena table over s3://<bucket>/<prefix>/<name>/. If the contract
# names a prefix the export does not write to, the crawler finds no objects, registers a
# table with no partitions, and every query against it succeeds and returns nothing.
run "the_published_contract_is_where_the_data_actually_lands" {
  command = plan

  assert {
    condition = alltrue([
      for e in aws_bcmdataexports_export.cur[0].export :
      length(e.destination_configurations) > 0 && alltrue([
        for d in e.destination_configurations :
        length(d.s3_destination) > 0 && alltrue([
          for s in d.s3_destination :
          s.s3_prefix == aws_ssm_parameter.cur_export_prefix[0].value
        ])
      ])
    ])
    error_message = "the published prefix must be the prefix the export delivers under — a mismatch yields a table with no partitions and queries that return nothing without erroring"
  }

  assert {
    condition = alltrue([
      for e in aws_bcmdataexports_export.cur[0].export :
      e.name == aws_ssm_parameter.cur_export_name[0].value
    ])
    error_message = "the published export name must be the export's own name — it is a path segment in the delivered layout, not a label"
  }

  assert {
    condition = alltrue([
      for e in aws_bcmdataexports_export.cur[0].export :
      alltrue([
        for d in e.destination_configurations :
        alltrue([
          for s in d.s3_destination :
          s.s3_bucket == aws_ssm_parameter.cur_export_bucket[0].value
        ])
      ])
    ])
    error_message = "the published bucket must be the bucket the export writes to"
  }
}

# Off means off, everywhere. A handle that survives its resource points consumers at a
# location nothing delivers to, which is the same empty table by another route.
run "disabling_the_export_leaves_no_dangling_handles" {
  command = plan

  variables {
    enable_cur_export = false
  }

  assert {
    condition = (
      length(aws_bcmdataexports_export.cur) == 0 &&
      length(aws_ssm_parameter.cur_export_bucket) == 0 &&
      length(aws_ssm_parameter.cur_export_prefix) == 0 &&
      length(aws_ssm_parameter.cur_export_name) == 0
    )
    error_message = "with the export disabled, neither the export nor any of its published handles may exist — a published location with no exporter behind it is a contract that resolves and delivers nothing"
  }
}
