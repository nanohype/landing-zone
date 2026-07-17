locals {
  tags = merge(var.tags, {
    Component = "org-scp"
    Team      = var.team
  })

  # Flatten policies → attachments: one entry per (policy_key, target_id)
  policy_attachments = flatten([
    for policy_key, policy in var.policies : [
      for target_id in policy.target_ids : {
        key        = "${policy_key}-${target_id}"
        policy_key = policy_key
        target_id  = target_id
      }
    ]
  ])
}

################################################################################
# Service Control Policies
################################################################################

resource "aws_organizations_policy" "this" {
  for_each = var.policies

  name        = each.key
  description = each.value.description
  type        = "SERVICE_CONTROL_POLICY"
  content     = each.value.policy
  tags        = merge(local.tags, { Name = each.key })
}

################################################################################
# Policy Attachments
################################################################################

resource "aws_organizations_policy_attachment" "this" {
  for_each = { for att in local.policy_attachments : att.key => att }

  policy_id = aws_organizations_policy.this[each.value.policy_key].id
  target_id = each.value.target_id
}

################################################################################
# SSM Parameters
################################################################################

resource "aws_ssm_parameter" "policy_ids" {
  for_each = var.policies

  name  = "/platform/${var.environment}/scp/policies/${each.key}/id"
  type  = "String"
  value = aws_organizations_policy.this[each.key].id
  tags  = local.tags
}
