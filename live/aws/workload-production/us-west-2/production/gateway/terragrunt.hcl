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
      deletion_protection      = true
      bot_control_enabled      = true
      logging_level            = "ERROR"
      waf_rate_limit           = 10000
      cognito_password_min     = 14
      cognito_access_token_hrs = 1
      throttle_rate_limit      = 1000
      throttle_burst_limit     = 2000
      throttle_quota_per_month = 10000000
    }
  }
}
