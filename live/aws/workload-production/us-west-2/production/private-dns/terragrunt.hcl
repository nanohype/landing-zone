include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/private-dns.hcl"
  merge_strategy = "deep"
}

# profile_id is cross-account (the shared-dns owner runs in the network account) and the path is
# env-specific, so the dependency lives here rather than in envcommon — the same shape the
# workload network adopt leaf uses for its shared_network dependency.
dependency "shared_dns" {
  config_path = "../../../../network/us-west-2/production/shared-dns"

  # mock_outputs feed the credential-less CI render; a real plan reads the live output.
  mock_outputs = {
    profile_id = "rp-mock000000000001"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  # adopt: associate the shared Profile with this account's cluster VPC (the multi-account path).
  # The profile_id comes straight from the shared-dns owner leaf's output — a consuming account
  # never hand-copies it. A single-account startup would instead run dns_mode = create with its own
  # private_zones; this leaf demonstrates the enterprise adopt shape.
  dns_mode   = "adopt"
  profile_id = dependency.shared_dns.outputs.profile_id
}
