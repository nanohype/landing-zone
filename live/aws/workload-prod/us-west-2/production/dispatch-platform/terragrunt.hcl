include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/dispatch-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Production: full safety bars (deletion_protection true by default
  # from variables.tf).

  rds_min_acu               = 1
  rds_max_acu               = 8
  rds_backup_retention_days = 14

  ses_sending_domain = "dispatch.example.com"

  raw_aggregations_lifecycle_days = 90
  voice_baseline_lifecycle_days   = 365
}
