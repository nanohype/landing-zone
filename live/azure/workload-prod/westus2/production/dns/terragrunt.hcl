include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/dns.hcl"
  merge_strategy = "deep"
}

inputs = {
  domain_name    = "example.com"
  create_dns_zone = true
  enable_dnssec  = true
}
