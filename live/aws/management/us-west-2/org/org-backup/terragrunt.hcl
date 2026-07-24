include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/org-backup.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Enable cross-account backup org-wide (the prerequisite for a workload account copying into
  # the central vault) and hand backup administration to the dedicated backup account.
  enable_cross_account_backup = true
  register_delegated_admin    = true
  delegated_admin_account_id  = "666666666666" # the backup account

  # Attach the policy at the organization root so every member account inherits the floor.
  # Replace r-0000 with the real organization root (or a parent OU) id at deploy time.
  target_ids = ["r-0000"]

  # The floor backs up every BackupPolicy-tagged resource to each member account's Default
  # vault on a daily schedule — coverage no account can opt out of, present even in an account
  # that never deployed its own backup component. The cross-account copy to the correct per-env
  # central vault stays the workload backup component's job (it knows which env's vault), so the
  # floor carries no copy_action.
  backup_policy = {
    schedule          = "cron(0 5 ? * * *)"
    target_vault_name = "Default"
    delete_after_days = 35
    tag_key           = "BackupPolicy"
    tag_values        = ["daily"]
  }
}
