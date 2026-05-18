include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/marshal-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Dev allows destroy/recreate without prod safety bars. Staging and
  # production both keep the secure defaults from the component's
  # variables.tf (deletion_protection + point_in_time_recovery both true).
  deletion_protection    = false
  point_in_time_recovery = false
}
