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
      deletion_protection    = false
      object_lock_enabled    = false
      point_in_time_recovery = false
      lifecycle_ia_days      = 30
      cost_ttl_days          = 90
    }
  }
}
