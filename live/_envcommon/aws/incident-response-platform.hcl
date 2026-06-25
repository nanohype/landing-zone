/**
 * incident-response-platform — env-shared inputs and dependency wiring.
 *
 * Per-env overrides go in
 * live/aws/<account>/<region>/<env>/incident-response-platform/terragrunt.hcl.
 *
 * IncidentResponse is a single-tenant component (no var.tenants map), so this
 * envcommon file is mostly dependency wiring: pull the OIDC bits from
 * the cluster component so the IRSA module can sign the trust policy.
 */

terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/incident-response-platform"
}

dependency "cluster" {
  config_path = "${get_path_relative_to_include("live")}/../cluster"

  mock_outputs = {
    cluster_name = "mock-eks"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  cluster_name = dependency.cluster.outputs.cluster_name
}
