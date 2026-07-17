include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/managed-monitoring.hcl"
  merge_strategy = "deep"
}

inputs = {
  amp_alert_rules_enabled = false
}
