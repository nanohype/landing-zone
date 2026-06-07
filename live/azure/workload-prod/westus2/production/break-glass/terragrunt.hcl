include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/break-glass.hcl"
  merge_strategy = "deep"
}

inputs = {
  trusted_principal_ids = []
  max_session_duration  = 3600
}
