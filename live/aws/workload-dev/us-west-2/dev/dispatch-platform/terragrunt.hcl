include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/dispatch-platform.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Dev: relaxed posture, smallest data plane.
  deletion_protection = false

  rds_min_acu               = 0.5
  rds_max_acu               = 2
  rds_backup_retention_days = 1

  # SES verified sending domain for dev. Real-mail can be disabled by
  # leaving this in the SES sandbox (default for new identities) — only
  # the verified domain can receive at first.
  ses_sending_domain = "dispatch-dev.example.com"

  raw_aggregations_lifecycle_days = 30
}
