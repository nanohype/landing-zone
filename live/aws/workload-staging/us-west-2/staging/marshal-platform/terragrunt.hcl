include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/marshal-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Staging mirrors production posture (deletion_protection +
  # point_in_time_recovery on by default). Drill the rollback path against
  # staging first; production stays in lockstep.
}
