# shared-backup — the owner side of central backup.
#
# A dedicated backup account runs this component in the DR region to hold the durable copy
# of every workload account's backups. Workload accounts keep a local vault for fast
# restores (components/aws/backup) and add a copy_action targeting the vault this component
# owns, so a recovery point survives the loss — compromise, or a confident delete — of the
# account that produced it.
#
# The seam this closes: a backup that lives only in the account it protects is one account
# event away from being gone with the thing it protected. Moving the durable copy to a
# separate account in a second region survives both an account-level event and a region
# loss (region-model R4's backup-and-restore DR posture, RPO ~24h).
#
# Cross-account copy into this vault is authorized two ways, both scoped to the org: the
# vault access policy admits backup:CopyIntoBackupVault, and the vault CMK admits the
# encrypt/decrypt/grant actions a copy job performs. The CMK is multi-region (region-model
# R5) because a cross-region restore cannot decrypt with the source region's key — this is
# the first key that has to be.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  tags = merge(var.tags, {
    Component = "shared-backup"
    Team      = var.team
  })
}

################################################################################
# Central vault CMK — multi-region, org-scoped
################################################################################

# multi_region = true so a replica can exist in a recovery region: a cross-region restore
# from this vault must be decryptable there, and the recovery-point key is the one that has
# to travel. Replica keys are minted per recovery region as a restore path demands one
# (aws_kms_replica_key), not eagerly for every region.
resource "aws_kms_key" "central" {
  description             = "${var.environment} central backup vault encryption key (multi-region)"
  deletion_window_in_days = var.kms_deletion_window
  enable_key_rotation     = true
  multi_region            = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowBackupServiceInThisAccount"
        Effect    = "Allow"
        Principal = { Service = "backup.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
      # Org member accounts encrypt copies into this vault under their own backup role. The
      # wildcard principal is bounded by aws:PrincipalOrgID — only a caller inside this
      # organization matches, and no external account can.
      {
        Sid       = "AllowOrgAccountsUseKey"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:PrincipalOrgID" = var.organization_id } }
      },
      # CreateGrant is carried separately so it can carry the GrantIsForAWSResource guard,
      # which the encrypt/decrypt actions above do not take. AWS Backup creates grants on
      # the caller's behalf; the guard confines the grant to an AWS service integration.
      {
        Sid       = "AllowOrgAccountsCreateGrant"
        Effect    = "Allow"
        Principal = "*"
        Action    = "kms:CreateGrant"
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:PrincipalOrgID" = var.organization_id }
          Bool         = { "kms:GrantIsForAWSResource" = "true" }
        }
      },
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "central" {
  name          = "alias/${var.environment}-central-backup"
  target_key_id = aws_kms_key.central.key_id
}

################################################################################
# Central vault
################################################################################

resource "aws_backup_vault" "central" {
  name        = "${var.environment}-central-backup-vault"
  kms_key_arn = aws_kms_key.central.arn

  tags = local.tags
}

# GOVERNANCE mode, deliberately not COMPLIANCE. Governance lock keeps the vault and its
# recovery points from deletion by any principal without the explicit override permission,
# which is the protection this vault needs. COMPLIANCE mode (set by changeable_for_days)
# becomes immutable after its grace period and cannot be removed by anyone including the
# root account or AWS — the same one-way door the estate already paid tuition on with an S3
# object lock. Take the override permission away from routine roles instead of taking the
# exit away from everyone. A named regulation, recorded in the central-backup ledger, is the
# only thing that flips a vault to COMPLIANCE.
resource "aws_backup_vault_lock_configuration" "central" {
  backup_vault_name  = aws_backup_vault.central.name
  min_retention_days = var.min_retention_days
  max_retention_days = var.max_retention_days
}

# Admit copy jobs from any account in the organization, and only this organization. This is
# the vault side of cross-account copy authorization; the CMK policy above is the key side.
resource "aws_backup_vault_policy" "central" {
  backup_vault_name = aws_backup_vault.central.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowOrgAccountsCopyInto"
      Effect    = "Allow"
      Principal = "*"
      Action    = "backup:CopyIntoBackupVault"
      Resource  = "*"
      Condition = { StringEquals = { "aws:PrincipalOrgID" = var.organization_id } }
    }]
  })
}

################################################################################
# Discovery
################################################################################

# The workload backup component needs this vault's ARN to target its copy_action. It runs in
# a different account, so a same-account SSM read does not reach it — these parameters are
# the in-account record; the cross-account value is carried to workload leaves as the known
# central_vault_arn input. Published here so the owner account has a single source of truth.
resource "aws_ssm_parameter" "central_vault_arn" {
  name  = "/${var.environment}/shared-backup/vault-arn"
  type  = "String"
  value = aws_backup_vault.central.arn

  tags = local.tags
}

resource "aws_ssm_parameter" "central_kms_key_arn" {
  name  = "/${var.environment}/shared-backup/kms-key-arn"
  type  = "String"
  value = aws_kms_key.central.arn

  tags = local.tags
}
