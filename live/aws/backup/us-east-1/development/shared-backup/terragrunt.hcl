include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/shared-backup.hcl"
  merge_strategy = "deep"
}

# The development central vault. Governance-locked with the default 1–365 day retention window;
# the workload-development backup component copies its recovery points here.
inputs = {}
