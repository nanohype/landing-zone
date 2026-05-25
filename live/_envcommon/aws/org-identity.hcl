terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/org-identity"
}

inputs = {
  team = "platform"
}
