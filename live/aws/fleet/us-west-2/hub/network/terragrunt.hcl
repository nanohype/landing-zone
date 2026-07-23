include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/network.hcl"
  merge_strategy = "deep"
}

# Hub-only: the hub provisions vended clusters' OIDC providers from inside this VPC.
# The EKS interface endpoint's private DNS shadows the IRSA OIDC issuer subdomain
# (oidc.eks.<region>.amazonaws.com) — a private hosted zone returns NXDOMAIN for the
# unmatched record with no public fallthrough — so disable it; OIDC then resolves
# publicly via NAT. Vended workload clusters keep the endpoint (default true).
inputs = {
  nat_gateways                  = 1
  enable_flow_logs              = false
  enable_interface_endpoints    = true
  enable_eks_interface_endpoint = false
}
