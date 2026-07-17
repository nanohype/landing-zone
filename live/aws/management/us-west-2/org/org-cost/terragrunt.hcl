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

  enable_compute_optimizer   = true
  enable_savings_plans_alarm = false
  enable_cur_export          = false

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
