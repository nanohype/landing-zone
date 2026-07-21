locals {
  ssm_prefix = "/gateway/${var.environment}/${var.tenant_id}"
}

resource "aws_ssm_parameter" "rest_api_id" {
  name  = "${local.ssm_prefix}/apigw-rest-api-id"
  type  = "String"
  value = aws_api_gateway_rest_api.this.id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "rest_api_endpoint" {
  name  = "${local.ssm_prefix}/apigw-rest-api-endpoint"
  type  = "String"
  value = aws_api_gateway_stage.this.invoke_url
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "stage_name" {
  name  = "${local.ssm_prefix}/apigw-stage-name"
  type  = "String"
  value = aws_api_gateway_stage.this.stage_name
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "waf_acl_arn" {
  name  = "${local.ssm_prefix}/waf-web-acl-arn"
  type  = "String"
  value = var.tenant_config.waf_enabled ? aws_wafv2_web_acl.this[0].arn : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "cognito_user_pool_id" {
  name  = "${local.ssm_prefix}/cognito-user-pool-id"
  type  = "String"
  value = var.tenant_config.cognito_enabled ? aws_cognito_user_pool.this[0].id : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "cognito_user_pool_arn" {
  name  = "${local.ssm_prefix}/cognito-user-pool-arn"
  type  = "String"
  value = var.tenant_config.cognito_enabled ? aws_cognito_user_pool.this[0].arn : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "cognito_client_id" {
  name  = "${local.ssm_prefix}/cognito-client-id"
  type  = "String"
  value = var.tenant_config.cognito_enabled ? aws_cognito_user_pool_client.this[0].id : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "cognito_domain" {
  name  = "${local.ssm_prefix}/cognito-domain"
  type  = "String"
  value = var.tenant_config.cognito_enabled ? aws_cognito_user_pool_domain.this[0].domain : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "api_key_id" {
  name  = "${local.ssm_prefix}/apigw-api-key-id"
  type  = "String"
  value = aws_api_gateway_api_key.this.id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "usage_plan_id" {
  name  = "${local.ssm_prefix}/apigw-usage-plan-id"
  type  = "String"
  value = aws_api_gateway_usage_plan.this.id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "gateway_admin_role_arn" {
  name  = "${local.ssm_prefix}/gateway-admin-role-arn"
  type  = "String"
  value = module.gateway_admin_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "gateway_auth_role_arn" {
  name  = "${local.ssm_prefix}/gateway-auth-role-arn"
  type  = "String"
  value = module.gateway_auth_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "namespace" {
  name  = "${local.ssm_prefix}/namespace"
  type  = "String"
  value = local.namespace
  tags  = local.tenant_tags
}
