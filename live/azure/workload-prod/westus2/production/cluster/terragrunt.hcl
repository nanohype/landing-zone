include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/azure/cluster.hcl"
  merge_strategy = "deep"
}

# Cluster API access mode:
#   - cluster_endpoint_public_access = true + TF_VAR_api_authorized_ip_ranges
#     unset → fully public endpoint (any AAD-authenticated user).
#   - cluster_endpoint_public_access = true + TF_VAR_api_authorized_ip_ranges
#     set in your shell → public endpoint restricted to those CIDRs.
#   - cluster_endpoint_public_access = false → private endpoint (Bastion/VPN
#     required for kubectl from a laptop).
#
# The IP allowlist is NOT committed here. Set it in your shell before apply:
#
#   MY_IP=$(curl -s -4 https://api.ipify.org)
#   export TF_VAR_api_authorized_ip_ranges="[\"$MY_IP/32\"]"
#   task apply CLOUD=azure ACCOUNT=workload-prod REGION=westus2 \
#     ENVIRONMENT=production COMPONENT=cluster
inputs = {
  cluster_endpoint_public_access = true
  system_node_count              = 3
}
