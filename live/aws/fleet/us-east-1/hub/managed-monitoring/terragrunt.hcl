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
# so the IRSA role auto-names hub-fleet-grafana-agent-amp and trusts
# system:serviceaccount:monitoring:grafana-agent on the hub cluster's OIDC issuer.
# AMG uses the component default permission/auth (SERVICE_MANAGED + AWS_SSO) — the
# fleet account must have IAM Identity Center enabled (or delegated) for AMG.
# Populate amg_admin_user_ids with fleet-account Identity Center user ids to grant
# console access; left empty the workspace comes up with no assigned users.
# amp_alert_rules_enabled stays off here, and the reason is structural rather than
# a preference: the Alertmanager routes every alert to one receiver, and a receiver
# with no destination is a valid config that discards silently. The workload
# accounts wire theirs to the severity topics their own observability component
# owns, but the hub runs no observability leaf — there is no topic in this account
# to route to. Turning the flag on without one installs a routing table to a black
# hole, so it is refused at plan.
#
# To enable it: stand up an alert destination in the fleet account (an
# observability leaf, or a topic the shared-services set already owns) and pass its
# ARN as amp_alert_sns_topic_arn, with amp_alert_kms_key_arn if it carries a CMK.
inputs = {
  amp_alert_rules_enabled = false
}
