output "rest_api_id" {
  description = "API Gateway REST API ID for this tenant."
  value       = aws_api_gateway_rest_api.this.id
}

output "rest_api_endpoint" {
  description = "Invoke URL of the tenant's deployed API Gateway stage."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "user_pool_id" {
  description = "Cognito user pool ID when cognito_enabled is set for this tenant; null otherwise."
  value       = var.tenant_config.cognito_enabled ? aws_cognito_user_pool.this[0].id : null
}

output "waf_acl_arn" {
  description = "WAFv2 web ACL ARN when waf_enabled is set for this tenant; null otherwise."
  value       = var.tenant_config.waf_enabled ? aws_wafv2_web_acl.this[0].arn : null
}
