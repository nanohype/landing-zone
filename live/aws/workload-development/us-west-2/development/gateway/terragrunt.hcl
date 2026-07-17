include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/gateway.hcl"
  merge_strategy = "deep"
}

inputs = {
  tenants = {
    default = {
      deletion_protection      = false
      bot_control_enabled      = false
      logging_level            = "INFO"
      waf_rate_limit           = 5000
      cognito_password_min     = 8
      cognito_access_token_hrs = 8
      throttle_rate_limit      = 100
      throttle_burst_limit     = 200
      throttle_quota_per_month = 1000000
    }
  }
}
