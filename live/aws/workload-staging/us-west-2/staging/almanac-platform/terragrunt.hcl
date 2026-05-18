include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/almanac-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Staging mirrors production posture (secure-by-default) at lower
  # capacity. Drill rollbacks here first.

  rds_min_acu               = 0.5
  rds_max_acu               = 4
  rds_backup_retention_days = 7

  redis_node_type          = "cache.t4g.small"
  redis_num_cache_clusters = 2
  redis_multi_az           = true
}
