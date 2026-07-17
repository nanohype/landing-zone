output "tenant_outputs" {
  description = "Per-tenant gateway outputs"
  value = {
    for tenant_id, tenant in module.tenant : tenant_id => {
      rest_api_id               = tenant.rest_api_id
      rest_api_endpoint         = tenant.rest_api_endpoint
      user_pool_id              = tenant.user_pool_id
      waf_acl_arn               = tenant.waf_acl_arn
      gateway_admin_policy_json = tenant.gateway_admin_policy_json
      gateway_auth_policy_json  = tenant.gateway_auth_policy_json
    }
  }
}
