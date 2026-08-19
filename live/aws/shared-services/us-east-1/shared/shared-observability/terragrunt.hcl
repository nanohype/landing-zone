include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/shared-observability.hcl"
  merge_strategy = "deep"
}

# The fleet-wide alarm topics. Wire the on-call address(es) here; every workload cluster's
# observability component adopts these topics and points its alarms at them.
inputs = {
  alert_email_endpoints = []
}
