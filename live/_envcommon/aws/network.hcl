terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/network"
}

# network is cluster-agnostic: it provisions one shared VPC per environment, named and
# tagged by environment only. The per-cluster subnet tags (kubernetes.io/cluster/<cluster>,
# karpenter.sh/discovery) are applied by the cluster component (aws_ec2_tag), so co-located
# sibling clusters in one account+environment each stamp their own onto the shared subnets.
inputs = {
  team = "platform"
}
