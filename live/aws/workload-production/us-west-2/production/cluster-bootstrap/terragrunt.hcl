include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/cluster-bootstrap.hcl"
  merge_strategy = "deep"
}

# Velero (staging/production only) and external-dns (every non-hub environment)
# both run on this cluster, so cluster-bootstrap stamps their bucket/domain
# annotations from the SSM parameters cluster-addons and dns publish. Order both
# before this leaf so those parameters exist by the time it applies.
dependencies {
  paths = ["../cluster-addons", "../dns"]
}

inputs = {
  cilium_operator_replicas = 2
  argocd_server_replicas   = 2
  argocd_repo_replicas     = 2
  argocd_appset_replicas   = 2

  enable_velero_backup = true
  enable_external_dns  = true
}
