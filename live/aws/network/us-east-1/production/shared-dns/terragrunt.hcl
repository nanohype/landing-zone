include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/shared-dns.hcl"
  merge_strategy = "deep"
}

inputs = {
  # One private zone shared to every production cluster VPC via the Route53 Profile. external-dns in
  # an adopting cluster writes service records here; the Profile makes them resolve fleet-wide.
  # The zone name is the same across environments — each env has its own Profile, and a cluster
  # VPC associates only its env's Profile, so the namespaces are isolated by Profile, not by name.
  private_zones = ["internal.nanohype"]

  # RAM-share the Profile to the workload-production account, which associates it with its cluster
  # VPC via the private-dns component. Placeholder account ID — a real engagement swaps in the
  # real workload account, matching the sibling shared-network leaf's consumer_account_ids.
  consumer_account_ids = ["111111111111"]
}
