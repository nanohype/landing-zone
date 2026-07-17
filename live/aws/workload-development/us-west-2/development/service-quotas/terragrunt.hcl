include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/service-quotas.hcl"
  merge_strategy = "deep"
}

inputs = {
  quota_threshold_percent = 80
}
