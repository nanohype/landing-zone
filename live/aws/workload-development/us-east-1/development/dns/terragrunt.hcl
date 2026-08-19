include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/dns.hcl"
  merge_strategy = "deep"
}

inputs = {
  domain_name        = "development.example.com"
  dns_mode           = "create"
  enable_dnssec      = false
  subdomain_prefixes = []

  acm_certificates = {
    wildcard = {
      domain_name               = "*.development.example.com"
      subject_alternative_names = ["development.example.com"]
    }
  }
}
