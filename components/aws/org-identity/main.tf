locals {
  tags = merge(var.tags, {
    Component = "org-identity"
    Team      = var.team
  })

  # Flatten managed policy attachments: {ps_name}-{policy_index} → {ps, policy_arn}
  managed_policy_attachments = flatten([
    for ps_name, ps in var.permission_sets : [
      for idx, policy_arn in ps.managed_policies : {
        key        = "${ps_name}-${idx}"
        ps_name    = ps_name
        policy_arn = policy_arn
      }
    ]
  ])

  # Flatten account assignments: {group}-{ps}-{account} → {group, ps, account_id}
  account_assignment_map = {
    for a in var.account_assignments :
    "${a.group}-${a.permission_set}-${a.account_id}" => a
  }
}

################################################################################
# SSO Instance Discovery
################################################################################

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

################################################################################
# Permission Sets
################################################################################

resource "aws_ssoadmin_permission_set" "this" {
  for_each = var.permission_sets

  name             = each.key
  description      = each.value.description
  instance_arn     = local.sso_instance_arn
  session_duration = each.value.session_duration

  tags = merge(local.tags, { Name = each.key })
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = {
    for att in local.managed_policy_attachments : att.key => att
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.ps_name].arn
  managed_policy_arn = each.value.policy_arn
}

resource "aws_ssoadmin_permission_set_inline_policy" "this" {
  for_each = {
    for ps_name, ps in var.permission_sets : ps_name => ps
    if ps.inline_policy != null
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
  inline_policy      = each.value.inline_policy
}

resource "aws_ssoadmin_permissions_boundary_attachment" "this" {
  for_each = {
    for ps_name, ps in var.permission_sets : ps_name => ps
    if ps.boundary_policy != null
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn

  permissions_boundary {
    managed_policy_arn = each.value.boundary_policy
  }
}

################################################################################
# Identity Store Groups
################################################################################

resource "aws_identitystore_group" "this" {
  for_each = var.groups

  identity_store_id = local.identity_store_id
  display_name      = each.key
  description       = each.value.description
}

################################################################################
# Account Assignments
################################################################################

resource "aws_ssoadmin_account_assignment" "this" {
  for_each = local.account_assignment_map

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.permission_set].arn

  principal_id   = aws_identitystore_group.this[each.value.group].group_id
  principal_type = "GROUP"

  target_id   = each.value.account_id
  target_type = "AWS_ACCOUNT"
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "sso_instance_arn" {
  name  = "/platform/${var.environment}/identity/sso-instance-arn"
  type  = "String"
  value = local.sso_instance_arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "identity_store_id" {
  name  = "/platform/${var.environment}/identity/identity-store-id"
  type  = "String"
  value = local.identity_store_id
  tags  = local.tags
}

resource "aws_ssm_parameter" "permission_set_arns" {
  for_each = aws_ssoadmin_permission_set.this

  name  = "/platform/${var.environment}/identity/permission-sets/${each.key}/arn"
  type  = "String"
  value = each.value.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "group_ids" {
  for_each = aws_identitystore_group.this

  name  = "/platform/${var.environment}/identity/groups/${each.key}/id"
  type  = "String"
  value = each.value.group_id
  tags  = local.tags
}
