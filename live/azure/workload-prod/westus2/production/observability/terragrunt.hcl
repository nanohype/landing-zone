include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/observability.hcl"
  merge_strategy = "deep"
}

inputs = {
  enable_cluster_alarms = true
  log_retention_days    = 90
  alert_email_endpoints = []
}
