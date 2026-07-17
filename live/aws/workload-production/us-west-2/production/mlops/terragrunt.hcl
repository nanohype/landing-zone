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
      deletion_protection           = true
      point_in_time_recovery        = true
      datasets_lifecycle_ia_days    = 90
      datasets_version_expiry_days  = 1825
      artifacts_lifecycle_ia_days   = 90
      artifacts_version_expiry_days = 1825
      run_ttl_days                  = 365
      deprecated_version_ttl_days   = 365
    }
  }
}
