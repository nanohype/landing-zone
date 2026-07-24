data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  tags = merge(var.tags, {
    Component = "backup"
    Team      = var.team
  })

  # Every plan rule copies its recovery points to the central vault (components/aws/shared-backup)
  # so a backup survives the loss of the account that produced it. A plan may carry its own
  # copy_action to override the destination or the copy retention; otherwise, when a central
  # vault is wired, the copy inherits that plan's own retention. With no central vault and no
  # per-plan override, no copy action is emitted (the create-mode default before central backup
  # is stood up).
  effective_copy_action = {
    for k, v in var.backup_plans : k => (
      v.copy_action != null ? v.copy_action : (
        var.central_vault_arn != "" ? {
          destination_vault_arn = var.central_vault_arn
          retention_days        = v.retention_days
        } : null
      )
    )
  }
}

################################################################################
# KMS Key for Backup Vault Encryption
################################################################################

resource "aws_kms_key" "backup" {
  description             = "KMS key for AWS Backup vault encryption"
  deletion_window_in_days = var.kms_deletion_window
  enable_key_rotation     = true

  tags = local.tags
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${var.environment}-backup"
  target_key_id = aws_kms_key.backup.key_id
}

################################################################################
# Backup Vault
################################################################################

resource "aws_backup_vault" "this" {
  name        = "${var.environment}-backup-vault"
  kms_key_arn = aws_kms_key.backup.arn

  tags = local.tags
}

# GOVERNANCE mode, deliberately not COMPLIANCE. Omitting changeable_for_days keeps the lock
# removable by a principal holding the explicit override permission (backup:DeleteBackupVault
# LockConfiguration); including it would put the vault in COMPLIANCE mode, immutable after the
# grace period and unremovable by anyone including the root account or AWS — the one-way door
# the estate already paid tuition on with an S3 object lock. The protection this vault needs is
# "no routine role can delete a recovery point," which governance mode plus a withheld override
# delivers without the irreversibility. A named regulation is the only thing that flips a vault
# to COMPLIANCE, recorded in the central-backup ledger at that time.
resource "aws_backup_vault_lock_configuration" "this" {
  count = var.enable_vault_lock ? 1 : 0

  backup_vault_name  = aws_backup_vault.this.name
  min_retention_days = var.min_retention_days
  max_retention_days = var.max_retention_days
}

################################################################################
# Backup Plans
################################################################################

resource "aws_backup_plan" "this" {
  for_each = var.backup_plans

  name = "${var.environment}-${each.key}"

  rule {
    rule_name         = each.key
    target_vault_name = aws_backup_vault.this.name
    schedule          = each.value.schedule

    lifecycle {
      delete_after       = each.value.retention_days
      cold_storage_after = each.value.cold_storage_after
    }

    dynamic "copy_action" {
      for_each = local.effective_copy_action[each.key] != null ? [local.effective_copy_action[each.key]] : []
      content {
        destination_vault_arn = copy_action.value.destination_vault_arn
        lifecycle {
          delete_after = copy_action.value.retention_days
        }
      }
    }
  }

  tags = local.tags
}

################################################################################
# Backup Selection (tag-based)
################################################################################

resource "aws_backup_selection" "this" {
  for_each = var.backup_plans

  name         = "${var.environment}-${each.key}"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.this[each.key].id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "BackupPolicy"
    value = each.key
  }
}

################################################################################
# IAM Role for AWS Backup
################################################################################

resource "aws_iam_role" "backup" {
  name = "${var.environment}-aws-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "backup.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

################################################################################
# Notifications
################################################################################

# Dedicated CMK for the notifications topic. AWS Backup publishes vault events;
# SSE-SNS makes SNS call kms:GenerateDataKey*/Decrypt as the backup service
# principal, so the key policy admits it (scoped to this account). Kept separate
# from the vault CMK so the topic grant never widens the recovery-point key.
resource "aws_kms_key" "notifications" {
  description             = "${var.environment} backup notifications topic encryption key"
  deletion_window_in_days = var.kms_deletion_window
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowBackupPublish"
        Effect    = "Allow"
        Principal = { Service = "backup.amazonaws.com" }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "notifications" {
  name          = "alias/${var.environment}-backup-notifications"
  target_key_id = aws_kms_key.notifications.key_id
}

resource "aws_sns_topic" "backup_notifications" {
  name              = "${var.environment}-backup-notifications"
  kms_master_key_id = aws_kms_key.notifications.arn

  tags = local.tags
}

resource "aws_sns_topic_subscription" "backup_email" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.backup_notifications.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_backup_vault_notifications" "this" {
  backup_vault_name   = aws_backup_vault.this.name
  sns_topic_arn       = aws_sns_topic.backup_notifications.arn
  backup_vault_events = ["BACKUP_JOB_FAILED", "BACKUP_JOB_EXPIRED", "RESTORE_JOB_FAILED"]
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "vault_arn" {
  name  = "/${var.environment}/backup/vault-arn"
  type  = "String"
  value = aws_backup_vault.this.arn

  tags = local.tags
}
