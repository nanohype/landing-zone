include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/cluster-bootstrap.hcl"
  merge_strategy = "deep"
}

# external-dns runs on this cluster (the addons-external-dns generator targets
# every non-hub environment), so cluster-bootstrap stamps the domain-filter
# annotation from the SSM parameter the dns component publishes. Order dns first
# so the parameter exists by the time this leaf applies. Velero is disabled here,
# so cluster-addons carries no ordering edge and enable_velero_backup stays off.
dependencies {
  paths = ["../dns"]
}

inputs = {
  cilium_operator_replicas = 1
  argocd_server_replicas   = 1
  argocd_repo_replicas     = 1
  argocd_appset_replicas   = 1

  # Pinned explicitly rather than inheriting the floor default: this cluster
  # already runs the full LGTM stack, and letting it fall to floor would delete
  # Loki, Tempo and the Grafana operator out from under live telemetry.
  observability_tier = "full"

  enable_external_dns = true
}
