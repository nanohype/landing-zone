include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/cost.hcl"
  merge_strategy = "deep"
}

inputs = {
  monthly_budget_limit     = 500
  budget_alert_thresholds  = [80, 100]
  enable_anomaly_detection = false
  enable_cur_report        = false
}
