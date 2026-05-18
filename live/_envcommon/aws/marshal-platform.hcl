/**
 * marshal-platform — env-shared inputs and dependency wiring.
 *
 * Per-env overrides go in
 * live/aws/<account>/<region>/<env>/marshal-platform/terragrunt.hcl.
 *
 * Marshal is a single-tenant component (no var.tenants map), so this
 * envcommon file is mostly dependency wiring: pull the OIDC bits from
 * the cluster component so the IRSA module can sign the trust policy.
 */

dependency "cluster" {
  config_path = "${get_path_relative_to_include("live")}/../cluster"

  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/MOCK"
    oidc_issuer       = "oidc.eks.us-west-2.amazonaws.com/id/MOCK"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  oidc_provider_arn = dependency.cluster.outputs.oidc_provider_arn
  oidc_issuer       = dependency.cluster.outputs.oidc_issuer
}
