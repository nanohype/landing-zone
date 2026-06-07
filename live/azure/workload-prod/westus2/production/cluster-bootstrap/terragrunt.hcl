include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/cluster-bootstrap.hcl"
  merge_strategy = "deep"
}

inputs = {
  cilium_operator_replicas = 2
  argocd_server_replicas   = 2
  argocd_repo_replicas     = 2
  argocd_appset_replicas   = 2
}
