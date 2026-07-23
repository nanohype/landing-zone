terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/network"
}

# network is cluster-agnostic: it provisions one shared VPC per environment, named and
# tagged by environment only. The per-cluster subnet tags (kubernetes.io/cluster/<cluster>,
# karpenter.sh/discovery) are applied by the cluster component (aws_ec2_tag), so co-located
# sibling clusters in one account+environment each stamp their own onto the shared subnets.
inputs = {
  team = "platform"

  # Minimal-footprint baseline: a create-mode leaf inherits the smallest working VPC and adds
  # capacity as it needs it, instead of starting at the full footprint. The other two footprint
  # levers are already minimal at the module default (enable_flow_logs = false, nat_gateways = 1),
  # so only endpoints is set here. A leaf grows by overriding, in its own inputs:
  #   enable_vpc_endpoints = true    — private AWS-API connectivity. Without it a cluster reaches
  #                                    the APIs over NAT, which works but pays NAT data per call.
  #   enable_flow_logs     = true    — VPC flow logs to CloudWatch, when audit matters.
  #   nat_gateways         = max_azs — one NAT per AZ for HA (the default 1 is a single shared NAT).
  # The staging / production leaves already set all three to the fuller values. Endpoints are inert
  # in adopt mode (the VPC owner runs them), so an adopt leaf inherits this harmlessly.
  enable_vpc_endpoints = false
}
