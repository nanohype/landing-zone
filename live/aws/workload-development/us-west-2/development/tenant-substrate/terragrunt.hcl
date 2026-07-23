include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/tenant-substrate.hcl"
  merge_strategy = "deep"
}

# The tenants map is rendered from the Platform CRs by the factory; empty until
# the first tenant declares datastores. Environment-specific overrides land here.
inputs = {
  tenants = {}
}
