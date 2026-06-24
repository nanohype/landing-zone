include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/managed-monitoring.hcl"
  merge_strategy = "deep"
}

# The hub's own observability backend: AMP (metrics) + AMG (dashboards) + the
# grafana-agent IRSA role. Same component the workload envs use; the envcommon
# wires cluster_name / oidc from ../cluster and environment ("hub") from env.hcl,
# so the IRSA role auto-names hub-eks-grafana-agent-amp and trusts
# system:serviceaccount:monitoring:grafana-agent on the hub cluster's OIDC issuer.
# AMG uses the component default permission/auth (SERVICE_MANAGED + AWS_SSO) — the
# fleet account must have IAM Identity Center enabled (or delegated) for AMG.
# Populate amg_admin_user_ids with fleet-account Identity Center user ids to grant
# console access; left empty the workspace comes up with no assigned users.
inputs = {
  amp_alert_rules_enabled = true
}
