include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/druid.hcl"
  merge_strategy = "deep"
}

inputs = {
  tenants = {
    default = {
      rds_min_acu         = 2
      rds_max_acu         = 16
      rds_backup_days     = 35
      msk_enabled         = true
      deletion_protection = true
      index_logs_expiry   = 90
    }
  }
}
