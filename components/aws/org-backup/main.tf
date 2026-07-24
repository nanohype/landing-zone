# org-backup — org-level backup enforcement, so coverage is a property of the organization
# rather than of whether an account remembered to deploy the backup component.
#
# Three levers, all run from the management account:
#   1. Cross-account backup enabled org-wide (aws_backup_global_settings) — the prerequisite
#      that lets a workload account copy into the central backup account's vault.
#   2. A delegated administrator for AWS Backup — the backup account administers backup
#      centrally instead of the management account.
#   3. An Organizations backup policy (type BACKUP_POLICY) attached to the org root or OUs —
#      a floor that backs up every BackupPolicy-tagged resource in every member account to
#      that account's Default vault and copies it to the central vault, whether or not the
#      account ever deployed its own backup component. Member accounts cannot opt out.
#
# The policy is generated from a structured input into the @@assign / @@append document shape
# AWS Organizations requires, with $account substituted per member account at evaluation.

locals {
  bp = var.backup_policy

  tags = merge(var.tags, {
    Component = "org-backup"
    Team      = var.team
  })

  # One rule, generated into the Organizations backup-policy shape. Cold storage and the
  # cross-account copy are optional blocks: omitted keys leave the setting unset rather than
  # writing a zero the effective policy would honor.
  rule = merge(
    {
      schedule_expression         = { "@@assign" = local.bp.schedule }
      start_backup_window_minutes = { "@@assign" = tostring(local.bp.start_window_minutes) }
      target_backup_vault_name    = { "@@assign" = local.bp.target_vault_name }
      lifecycle = merge(
        { delete_after_days = { "@@assign" = tostring(local.bp.delete_after_days) } },
        local.bp.cold_storage_after_days > 0 ? {
          move_to_cold_storage_after_days = { "@@assign" = tostring(local.bp.cold_storage_after_days) }
        } : {}
      )
    },
    local.bp.copy_to_central_vault_arn != "" ? {
      copy_actions = {
        (local.bp.copy_to_central_vault_arn) = {
          target_backup_vault_arn = { "@@assign" = local.bp.copy_to_central_vault_arn }
          lifecycle               = { delete_after_days = { "@@assign" = tostring(local.bp.copy_delete_after_days) } }
        }
      }
    } : {}
  )

  backup_policy_doc = {
    plans = {
      (local.bp.plan_name) = {
        regions = { "@@assign" = local.bp.regions }
        rules   = { (local.bp.rule_name) = local.rule }
        selections = {
          tags = {
            "${local.bp.tag_key}-selection" = {
              iam_role_arn = { "@@assign" = local.bp.iam_role_arn }
              tag_key      = { "@@assign" = local.bp.tag_key }
              tag_value    = { "@@assign" = local.bp.tag_values }
            }
          }
        }
      }
    }
  }
}

################################################################################
# Cross-account backup enablement
################################################################################

# Enables copying recovery points across accounts in the org — the prerequisite for a
# workload account's copy_action to reach the central backup account's vault. Off leaves the
# org unable to centralize backups.
resource "aws_backup_global_settings" "this" {
  count = var.enable_cross_account_backup ? 1 : 0

  global_settings = {
    isCrossAccountBackupEnabled = "true"
  }
}

################################################################################
# Delegated administrator
################################################################################

# Hand backup administration to the dedicated backup account so the management account is not
# the day-to-day operator of backup policy. Registered for the backup service principal.
resource "aws_organizations_delegated_administrator" "backup" {
  count = var.register_delegated_admin ? 1 : 0

  account_id        = var.delegated_admin_account_id
  service_principal = "backup.amazonaws.com"
}

################################################################################
# Organization backup policy
################################################################################

resource "aws_organizations_policy" "backup" {
  name        = "${var.environment}-org-backup"
  description = "Org backup floor: every ${local.bp.tag_key}-tagged resource is backed up and copied to the central vault, in every member account."
  type        = "BACKUP_POLICY"
  content     = jsonencode(local.backup_policy_doc)
  tags        = merge(local.tags, { Name = "${var.environment}-org-backup" })
}

resource "aws_organizations_policy_attachment" "backup" {
  for_each = toset(var.target_ids)

  policy_id = aws_organizations_policy.backup.id
  target_id = each.value
}

################################################################################
# Discovery
################################################################################

resource "aws_ssm_parameter" "policy_id" {
  name  = "/platform/${var.environment}/backup/org-policy-id"
  type  = "String"
  value = aws_organizations_policy.backup.id
  tags  = local.tags
}
