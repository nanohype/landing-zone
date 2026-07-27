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
  # the placeholder in live/aws/backup/account.hcl is what makes the ARN real;
  # until then the copy_action still targets a well-formed ARN and fails only
  # at apply time if the vault does not exist yet — not silently omitted.
  backup_account = read_terragrunt_config("${dirname(find_in_parent_folders("cloud.hcl"))}/backup/account.hcl")

  # shared-backup lives in the DR region (region-model R4), not the primary.
  # Read the same region.hcl the shared-backup leaves sit under so a DR-region
  # move is one file, not a constant here and another under live/aws/backup/.
  central_backup_region = read_terragrunt_config(
    "${dirname(find_in_parent_folders("cloud.hcl"))}/backup/us-east-1/region.hcl"
  ).locals.region

  central_vault_arn = format(
    "arn:aws:backup:%s:%s:backup-vault:%s-central-backup-vault",
    local.central_backup_region,
    local.backup_account.locals.account_id,
    local.environment,
  )
}

inputs = {
  team              = "sre"
  central_vault_arn = local.central_vault_arn
}
