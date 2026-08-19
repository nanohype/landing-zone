include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/org-cost.hcl"
  merge_strategy = "deep"
}

inputs = {
  org_budget_limit        = 10000
  budget_alert_thresholds = [50, 80, 100, 120]
  budget_alert_emails     = []

  enable_anomaly_detection = true
  anomaly_threshold        = 100

  enable_compute_optimizer = true

  # The account's one Cost and Usage Report. A CUR has no filter — it always covers the
  # whole account — so this belongs to the single org-scoped root rather than to any
  # per-environment one, and there is exactly one of it.
  #
  # It is the billed side of every budget the platform enforces. Consumers read its
  # location from /platform/org/cost/cur-export-{bucket,prefix,name} and build their own
  # query layer over it; nothing else in the org defines a CUR.
  enable_cur_export = true

  cost_categories = {
    ByEnvironment = {
      rule_version = "1"
      rules = [
        {
          value = "Production"
          rule = {
            tags = { key = "Environment", values = ["production"] }
          }
        },
        {
          value = "Staging"
          rule = {
            tags = { key = "Environment", values = ["staging"] }
          }
        },
        {
          value = "Development"
          rule = {
            tags = { key = "Environment", values = ["development"] }
          }
        },
      ]
      default_value = "Untagged"
    }
  }
}
