include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/dns.hcl"
  merge_strategy = "deep"
}

inputs = {
  domain_name        = "example.com"
  create_hosted_zone = true
  enable_dnssec      = true
  subdomain_prefixes = []

  acm_certificates = {
    wildcard = {
      domain_name               = "*.example.com"
      subject_alternative_names = ["example.com"]
    }
  }
}
