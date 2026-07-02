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
      deletion_protection           = true
      msk_enabled                   = true
      batch_max_vcpus               = 32
      batch_type                    = "FARGATE"
      raw_lifecycle_ia_days         = 60
      raw_lifecycle_expiry_days     = 180
      staging_lifecycle_expiry_days = 60
      curated_version_expiry_days   = 180
    }
  }
}
