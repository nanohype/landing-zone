include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/private-dns.hcl"
  merge_strategy = "deep"
}

inputs = {
  # create: this account owns its private zone and associates it with its own cluster
  # VPC (vpc_id comes from the same-account network leaf via envcommon). external-dns
  # writes service records into it. Nothing outside this account is involved, so the
  # environment comes up from a standing start.
  #
  # The adopt shape — associating a Route53 Profile that the shared-dns owner in the
  # network account RAM-shares — is at live/aws/reference-adopt/, outside every
  # workload account. See the README there for why.
  dns_mode      = "create"
  private_zones = ["internal.example.com"]
}
