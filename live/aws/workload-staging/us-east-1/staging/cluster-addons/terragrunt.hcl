include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/cluster-addons.hcl"
  merge_strategy = "deep"
}

inputs = {
  velero_enabled         = true
  opencost_enabled       = true
  keda_enabled           = true
  argo_events_enabled    = false
  argo_workflows_enabled = false
}
