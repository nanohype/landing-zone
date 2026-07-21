locals {
  ssm_prefix = "/governance/${var.environment}/${var.tenant_id}"
}

resource "aws_ssm_parameter" "audit_bucket" {
  name  = "${local.ssm_prefix}/s3-audit-bucket"
  type  = "String"
  value = module.audit_bucket.s3_bucket_id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "audit_kms_key_arn" {
  name  = "${local.ssm_prefix}/s3-audit-kms-key-arn"
  type  = "String"
  value = aws_kms_key.audit.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "guardrail_bucket" {
  name  = "${local.ssm_prefix}/s3-guardrail-bucket"
  type  = "String"
  value = module.guardrail_bucket.s3_bucket_id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "audit_table" {
  name  = "${local.ssm_prefix}/dynamodb-audit-table"
  type  = "String"
  value = aws_dynamodb_table.audit.name
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "cost_table" {
  name  = "${local.ssm_prefix}/dynamodb-cost-table"
  type  = "String"
  value = aws_dynamodb_table.cost.name
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "eventbridge_bus_name" {
  name  = "${local.ssm_prefix}/eventbridge-bus-name"
  type  = "String"
  value = var.tenant_config.event_bridge_enabled ? aws_cloudwatch_event_bus.this[0].name : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "eventbridge_bus_arn" {
  name  = "${local.ssm_prefix}/eventbridge-bus-arn"
  type  = "String"
  value = var.tenant_config.event_bridge_enabled ? aws_cloudwatch_event_bus.this[0].arn : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "audit_writer_role_arn" {
  name  = "${local.ssm_prefix}/audit-writer-role-arn"
  type  = "String"
  value = module.audit_writer_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "governance_api_role_arn" {
  name  = "${local.ssm_prefix}/governance-api-role-arn"
  type  = "String"
  value = module.governance_api_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "namespace" {
  name  = "${local.ssm_prefix}/namespace"
  type  = "String"
  value = local.namespace
  tags  = local.tenant_tags
}
