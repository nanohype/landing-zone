include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/backup.hcl"
  merge_strategy = "deep"
}

inputs = {
  enable_backup_vault = true
}
