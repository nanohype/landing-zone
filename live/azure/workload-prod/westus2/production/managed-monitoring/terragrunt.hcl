include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/managed-monitoring.hcl"
  merge_strategy = "deep"
}

inputs = {
  grafana_sku = "Standard"
  # Zone redundancy is region-gated by Microsoft, not a product tier choice.
  # As of 2026-05, westus2 is NOT on the supported list (eastus, eastus2,
  # westus3, southcentralus, northeurope, uksouth, francecentral, koreacentral,
  # eastasia, centralindia, canadacentral, norwayeast, australiaeast).
  # Set to true ONLY when deploying to a region from that list — otherwise
  # the Grafana resource create fails with `ZoneRedundancyNotSupported`.
  grafana_zone_redundancy_enabled = false
}
