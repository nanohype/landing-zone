terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/shared-network"
}

# shared-network is the owner side of the cross-account adopt topology: a central
# network-owner account runs one shared VPC per environment, draws its CIDR from the org
# IPAM env sub-pool (discovered by the org-ipam-<environment> tag), and RAM-shares its
# subnets to the matching workload account. No dependency block: the IPAM pool arrives over
# RAM, not through this repo's state, so it is discovered by tag inside the component rather
# than wired from another live leaf's outputs.
inputs = {
  team = "platform"
}
