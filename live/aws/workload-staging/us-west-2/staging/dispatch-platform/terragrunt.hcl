include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/dispatch-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Staging mirrors production posture (secure defaults) at lower capacity.

  rds_min_acu               = 0.5
  rds_max_acu               = 4
  rds_backup_retention_days = 7

  ses_sending_domain = "dispatch-staging.example.com"
}
