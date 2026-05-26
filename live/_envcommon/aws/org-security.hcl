terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/org-security"
}

inputs = {
  team = "platform"
}
