include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/competitive-intelligence-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Production: every safety bar on (deletion_protection defaults to true
  # in the component's variables.tf).

  rds_min_acu               = 1
  rds_max_acu               = 8
  rds_backup_retention_days = 14
}
