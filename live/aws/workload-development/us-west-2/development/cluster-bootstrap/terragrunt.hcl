include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/cluster-bootstrap.hcl"
  merge_strategy = "deep"
}

inputs = {
  cilium_operator_replicas = 1
  argocd_server_replicas   = 1
  argocd_repo_replicas     = 1
  argocd_appset_replicas   = 1
}
