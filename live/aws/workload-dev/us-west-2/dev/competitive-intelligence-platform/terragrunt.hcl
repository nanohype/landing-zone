include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/competitive-intelligence-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Dev relaxes safety bars and runs the smallest data-plane footprint.
  deletion_protection = false

  # Aurora Serverless v2: 0.5 ACU min, 2 ACU ceiling
  rds_min_acu               = 0.5
  rds_max_acu               = 2
  rds_backup_retention_days = 1
}
