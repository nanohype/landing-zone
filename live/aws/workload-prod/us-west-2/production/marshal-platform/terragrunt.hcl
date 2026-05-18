include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/marshal-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Production: every safety bar on (deletion_protection +
  # point_in_time_recovery default to true in the component's variables.tf).
  # No overrides here — accept the secure defaults.
}
