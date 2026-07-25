locals {
  # A reference account, not a deployable one. This tree holds the org's worked
  # adopt-mode wiring so a real engagement has a concrete, CI-verified shape to
  # copy. Nothing here is meant to be applied as-is — see README.md beside this
  # file. The id is a placeholder and stays one.
  account_id    = "555555555555" # Replace with the consuming spoke account ID
  account_alias = "reference-adopt"
}
