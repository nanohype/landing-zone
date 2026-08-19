include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/secrets.hcl"
  merge_strategy = "deep"
}

inputs = {
  kms_deletion_window = 14
  enable_key_rotation = true
  secrets             = {}
}
