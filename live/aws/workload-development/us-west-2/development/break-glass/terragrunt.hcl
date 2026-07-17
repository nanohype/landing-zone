include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/break-glass.hcl"
  merge_strategy = "deep"
}

inputs = {
  trusted_account_ids  = ["123456789012"]
  max_session_duration = 3600
}
