include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/mlops.hcl"
  merge_strategy = "deep"
}

inputs = {
  tenants = {
    default = {
      deletion_protection           = false
      point_in_time_recovery        = false
      datasets_lifecycle_ia_days    = 30
      datasets_version_expiry_days  = 365
      artifacts_lifecycle_ia_days   = 30
      artifacts_version_expiry_days = 365
      run_ttl_days                  = 90
      deprecated_version_ttl_days   = 90
    }
  }
}
