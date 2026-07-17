include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/governance.hcl"
  merge_strategy = "deep"
}

inputs = {
  tenants = {
    default = {
      deletion_protection    = true
      object_lock_enabled    = true
      point_in_time_recovery = true
      lifecycle_ia_days      = 90
      cost_ttl_days          = 365
    }
  }
}
