################################################################################
# Restore testing — proves a recovery point is actually restorable, on a schedule,
# with no human initiating it. B4's answer to "an untested backup is a belief."
################################################################################

# Restore-testing-plan and -selection names accept only alphanumerics and underscores, so the
# hyphenated environment token is normalized here.
locals {
  restore_testing_name = "${replace(var.environment, "-", "_")}_restore_testing"
}

resource "aws_backup_restore_testing_plan" "this" {
  count = var.restore_testing.enabled ? 1 : 0

  name                         = local.restore_testing_name
  schedule_expression          = var.restore_testing.schedule
  schedule_expression_timezone = "UTC"
  start_window_hours           = var.restore_testing.start_window_hours

  recovery_point_selection {
    algorithm             = "LATEST_WITHIN_WINDOW"
    include_vaults        = [aws_backup_vault.this.arn]
    recovery_point_types  = ["SNAPSHOT"]
    selection_window_days = var.restore_testing.selection_window_days
  }

  tags = local.tags
}

# One selection per protected-resource type. protected_resource_arns = ["*"] tests every
# recovery point of that type in the vault, restored under the backup role — which already
# carries AWSBackupServiceRolePolicyForRestores. The restored resource is validated for the
# validation window, then cleaned up by AWS Backup.
resource "aws_backup_restore_testing_selection" "this" {
  for_each = var.restore_testing.enabled ? toset(var.restore_testing.resource_types) : toset([])

  name                      = "${replace(lower(each.value), "-", "_")}_test"
  restore_testing_plan_name = aws_backup_restore_testing_plan.this[0].name
  protected_resource_type   = each.value
  iam_role_arn              = aws_iam_role.backup.arn
  protected_resource_arns   = ["*"]
  validation_window_hours   = var.restore_testing.validation_window_hours
}
