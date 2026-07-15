include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/pipeline.hcl"
  merge_strategy = "deep"
}

inputs = {
  tenants = {
    default = {
      deletion_protection           = false
      msk_enabled                   = false
      batch_max_vcpus               = 16
      batch_type                    = "FARGATE_SPOT"
      raw_lifecycle_ia_days         = 30
      raw_lifecycle_expiry_days     = 90
      staging_lifecycle_expiry_days = 30
      curated_version_expiry_days   = 90
    }
  }
}
