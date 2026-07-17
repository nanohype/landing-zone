include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/cluster.hcl"
  merge_strategy = "deep"
}

# The hub runs Crossplane + provider-opentofu + ArgoCD (and, later, portal) on the
# system node group — it does NOT install the eks-gitops Karpenter catalog — so the
# system pool carries the whole control-plane load. Public endpoint so you can reach
# the API for kubectl / portal / ArgoCD; tighten with
# cluster_endpoint_public_access_cidrs (your CIDR) or go private + bastion once the
# hub is settled.
inputs = {
  # The hub cluster IS the fleet control plane, so its base name is "fleet"
  # (→ hub-fleet), distinct from workload clusters which default to <env>-platform.
  cluster_name                   = "fleet"
  cluster_endpoint_public_access = true
  # cluster_endpoint_public_access_cidrs = ["<your-cidr>/32"]
  system_node_min_size     = 2
  system_node_desired_size = 2
  system_node_max_size     = 4
  system_node_disk_size    = 50
}
