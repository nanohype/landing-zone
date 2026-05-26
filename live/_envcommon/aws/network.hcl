terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/network"
}

inputs = {
  cluster_name = "eks"
  team         = "platform"
}
