include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/almanac-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Dev relaxes safety bars and runs the smallest data-plane footprint.
  deletion_protection    = false
  point_in_time_recovery = false

  # Aurora Serverless v2: 0.5 ACU min, 2 ACU ceiling
  rds_min_acu               = 0.5
  rds_max_acu               = 2
  rds_backup_retention_days = 1

  # Redis: single t4g.micro, no failover
  redis_node_type          = "cache.t4g.micro"
  redis_num_cache_clusters = 1
  redis_multi_az           = false

  # Audit retention: shorter in dev so the bucket doesn't accumulate
  audit_ttl_days          = 30
  audit_s3_lifecycle_days = 90
}
