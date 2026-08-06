terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/backup"
}

locals {
  env_vars    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  environment = local.env_vars.locals.environment

  # Backup account that owns shared-backup in the DR region. Cross-account SSM is
  # not readable from workload accounts, so the central vault ARN is composed
  # from the account catalog + the vault naming convention
  # (<env>-central-backup-vault) rather than looked up at plan time. Replacing
  # the placeholder in live/aws/backup/account.hcl is what makes the ARN real —
  # and until it is replaced, no ARN is composed at all (see below).
  backup_account = read_terragrunt_config("${dirname(find_in_parent_folders("cloud.hcl"))}/backup/account.hcl")

  # shared-backup lives in the DR region (region-model R4), not the primary.
  # Read the same region.hcl the shared-backup leaves sit under so a DR-region
  # move is one file, not a constant here and another under live/aws/backup/.
  central_backup_region = read_terragrunt_config(
    "${dirname(find_in_parent_folders("cloud.hcl"))}/backup/us-east-1/region.hcl"
  ).locals.region

  # The placeholder in live/aws/backup/account.hcl means "the dedicated backup
  # account has not been provisioned". Composing a destination ARN from it emits
  # a copy_action into every workload plan pointing at an account that is not in
  # the organization — and cross-account copy needs all three of: both accounts
  # in one org, the destination vault existing with a CopyIntoBackupVault
  # policy, and the feature enabled from the management account. None of them
  # can be true of an account that does not exist.
  #
  # Empty is the documented create-mode value (components/aws/backup
  # variables.tf), and it emits no copy action at all: recovery points stay
  # local, which is honest for a single-account deployment, rather than
  # declaring a durability guarantee that terminates nowhere.
  backup_account_provisioned = local.backup_account.locals.account_id != "666666666666"

  central_vault_arn = local.backup_account_provisioned ? format(
    "arn:aws:backup:%s:%s:backup-vault:%s-central-backup-vault",
    local.central_backup_region,
    local.backup_account.locals.account_id,
    local.environment,
  ) : ""
}

inputs = {
  team              = "sre"
  central_vault_arn = local.central_vault_arn
}
