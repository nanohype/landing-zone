include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/backup.hcl"
  merge_strategy = "deep"
}

inputs = {
  enable_vault_lock = true

  backup_plans = {
    daily = {
      schedule       = "cron(0 3 * * ? *)"
      retention_days = 35
    }
    weekly = {
      schedule       = "cron(0 4 ? * SUN *)"
      retention_days = 90
    }
    monthly = {
      schedule       = "cron(0 5 1 * ? *)"
      retention_days = 365
    }
  }
}
