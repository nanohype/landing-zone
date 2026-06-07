include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/cost.hcl"
  merge_strategy = "deep"
}

inputs = {
  monthly_budget_limit    = 10000
  budget_alert_thresholds = [50, 80, 100, 120]
}
