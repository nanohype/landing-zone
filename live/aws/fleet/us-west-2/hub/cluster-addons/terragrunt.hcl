include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/cluster-addons.hcl"
  merge_strategy = "deep"
}

# The hub's addon IRSA roles. The eks-gitops observability stack (grafana-agent,
# loki, tempo, opencost, kube-state-metrics) and external-secrets bind to these
# per-addon roles via their ServiceAccount annotations; the envcommon wires the
# hub cluster's OIDC, so the roles auto-name hub-eks-<addon> (hub-eks-external-secrets,
# hub-eks-loki, hub-eks-tempo, hub-eks-opencost, hub-eks-cert-manager, ...).
# velero/keda/argo off (workload-plane concerns the hub doesn't run); the rest —
# opencost, cert-manager, external-secrets, loki/tempo, lb-controller, external-dns —
# stay on by the component defaults.
inputs = {
  velero_enabled         = false
  keda_enabled           = false
  argo_events_enabled    = false
  argo_workflows_enabled = false
}
