include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/druid-catalog.hcl"
  merge_strategy = "deep"
}

inputs = {
  tenant_name         = "analytics"
  postgres_sku_name   = "GP_Standard_D4s_v3"
  postgres_storage_mb = 131072
}
