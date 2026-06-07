include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/secrets.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Personal/portfolio posture: short retention, no purge protection. This is
  # the AKS variant of a multi-cloud template, not a regulated workload — we
  # want destroy/recreate cycles to be clean (no 90-day vault-name quarantine).
  # For a real regulated env, flip purge_protection_enabled back to the
  # component default (true) and bump retention to 90.
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}
