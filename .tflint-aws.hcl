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
