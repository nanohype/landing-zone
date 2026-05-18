include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/almanac-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Production: every safety bar on (deletion_protection + PITR default
  # to true in the component's variables.tf).

  rds_min_acu               = 1
  rds_max_acu               = 8
  rds_backup_retention_days = 14

  redis_node_type          = "cache.m7g.large"
  redis_num_cache_clusters = 2
  redis_multi_az           = true

  audit_s3_lifecycle_days = 365
}
