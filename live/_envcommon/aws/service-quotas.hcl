terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/service-quotas"
}

inputs = {
  team = "platform"
}
