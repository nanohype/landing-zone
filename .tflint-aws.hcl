# tflint config for the AWS component tree. CI and `task lint` run this at
# `--minimum-failure-severity=notice`, so every rule below is a HARD gate — a build
# fails on an undocumented variable/output, an unused declaration, or a missing
# version constraint. tflint rule severities are fixed per rule (documented-*/naming
# are `notice`, unused-declaration and required-version/providers are `warning`), so
# the runner threshold, not a per-rule setting, is what makes them all block.
#
# The one sanctioned exception is the uniform envcommon interface: every component
# declares the same `region`/`environment`/`vpc_id`/`cluster_sg_id`/`cluster_name`
# inputs so `live/_envcommon/aws/*.hcl` can wire them uniformly (see CLAUDE.md,
# "Dependency wiring lives in live/_envcommon"). A component that doesn't consume one
# still declares it; those declarations carry an inline `# tflint-ignore:
# terraform_unused_declarations` with a one-line rationale. Genuine dead code — any
# other unused variable, local, or data source — is not suppressed; it must be removed.
config {
  call_module_type = "local"
}

plugin "aws" {
  enabled = true
  version = "0.34.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
  # Verify the plugin via its PGP signature rather than GitHub artifact
  # attestations. tflint's attestation path (sigstore-go) panics with a nil
  # pointer in bundle.TlogEntries during `tflint --init` — a widespread upstream
  # break after GitHub changed its attestation bundle format, affecting every
  # current tflint release. PGP is the maintainer-documented workaround and keeps
  # `tflint --init` from crashing before any linting runs.
  signature = "pgp"
}

rule "terraform_naming_convention" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}
