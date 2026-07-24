include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/cluster-bootstrap.hcl"
  merge_strategy = "deep"
}

# Cilium + ArgoCD on the hub. The hub's ArgoCD applies the per-cluster Cluster CRs
# (eks-gitops clusters-appset) once Crossplane + the Cluster API are installed on top.
inputs = {
  cilium_operator_replicas = 1
  argocd_server_replicas   = 1
  argocd_repo_replicas     = 1
  argocd_appset_replicas   = 1

  # The hub already runs the full LGTM stack and has a managed-monitoring
  # workspace, so it is pinned explicitly rather than inheriting the floor
  # default — flipping it would remove telemetry from a live cluster.
  observability_tier = "full"
}
