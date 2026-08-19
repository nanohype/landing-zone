include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/org-networking.hcl"
  merge_strategy = "deep"
}

inputs = {
  enable_transit_gateway              = true
  tgw_asn                             = 64512
  tgw_default_route_table_association = true
  tgw_default_route_table_propagation = true

  ram_principals = []

  enable_ipam         = true
  ipam_top_level_cidr = "10.0.0.0/8"

  ipam_pools = {
    development = {
      cidr        = "10.0.0.0/12"
      description = "Development environment pool"
    }
    staging = {
      cidr        = "10.16.0.0/12"
      description = "Staging environment pool"
    }
    production = {
      cidr        = "10.32.0.0/12"
      description = "Production environment pool"
    }
  }

  enable_resolver = false
  resolver_rules  = {}
}
